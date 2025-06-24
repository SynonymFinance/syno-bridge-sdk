// SPDX-License-Identifier: Apache 2
pragma solidity ^0.8.0;

import {
    WormholeRelayerTest,
    ChainInfo,
    ActiveFork,
    IWormhole,
    WormholeSimulator,
    CircleMessageTransmitterSimulator,
    CCTPMessageLib,
    DeliveryInstruction,
    decodeDeliveryInstruction,
    decodeVaaKey,
    decodeCCTPKey,
    EvmExecutionInfoV1,
    decodeEvmExecutionInfoV1,
    RedeliveryInstruction,
    decodeRedeliveryInstruction,
    DeliveryOverride,
    encode,
    BytesParsing
} from "./WormholeRelayerTest.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import "../Utils.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IWormholeTunnel} from "../interfaces/IWormholeTunnel.sol";
import {WormholeTunnel} from "../WormholeTunnel.sol";
import {DelayingWormholeTunnel} from "./DelayingWormholeTunnel.t.sol";

import "forge-std/Test.sol";

contract BaseWormholeTunnelTest is WormholeRelayerTest {
    using BytesParsing for bytes;

    ChainInfo spokeFork;
    ChainInfo hubFork;

    mapping(uint16 => DelayingWormholeTunnel) public tunnels;
    mapping(uint16 => uint256) private forkIds;

    uint256 public timestamp;

    // internal mappings for relaying
    mapping(bytes32 => bytes[]) pastEncodedSignedVaas;
    mapping(bytes32 => bytes) pastEncodedDeliveryVAA;

    /**
     * @dev setting the default active forks
     */
    constructor() {
        spokeFork = chainInfosMainnet[2]; // ethereum
        hubFork = chainInfosMainnet[23]; // arbitrum

        ChainInfo[] memory forks = new ChainInfo[](2);
        forks[0] = spokeFork;
        forkIds[spokeFork.chainId] = 0;

        forks[1] = hubFork;
        forkIds[hubFork.chainId] = 1;

        setActiveForks(forks);
    }

    function usdcIERC20(ChainInfo memory fork) internal pure returns (IERC20) {
        // WH uses its own IERC20 internally so a clunky re-cast to OZ IERC20 is needed
        return IERC20(address(fork.USDC));
    }

    function setUpFork(ActiveFork memory fork) public virtual override {
        ProxyAdmin proxyAdmin = new ProxyAdmin(address(this));
        DelayingWormholeTunnel implementation = new DelayingWormholeTunnel();
        bytes memory initData = abi.encodeWithSelector(
            WormholeTunnel.initialize.selector,
            fork.wormhole,
            fork.tokenBridge,
            fork.relayer,
            fork.circleMessageTransmitter,
            fork.circleTokenMessenger,
            fork.USDC
        );
        address proxy = address(new TransparentUpgradeableProxy(
            address(implementation),
            address(proxyAdmin),
            initData
        ));
        tunnels[fork.chainId] = DelayingWormholeTunnel(payable(proxy));
    }

    function switchToHub() internal {
        switchToChain(hubFork.chainId);
    }

    function switchToSpoke() internal {
        switchToChain(spokeFork.chainId);
    }

    function switchToChain(uint16 chainId) internal {
        switchToFork(forkIds[chainId]);
    }

    function switchToFork(uint256 forkId) internal {
        uint256 preSwitchTime = block.timestamp;
        vm.selectFork(forkId);
        uint256 postSwitchTime = block.timestamp;
        if (timestamp < preSwitchTime || timestamp < postSwitchTime) {
            timestamp = preSwitchTime > postSwitchTime ? preSwitchTime : postSwitchTime;
        }
        vm.warp(timestamp);
        assertEq(block.timestamp, timestamp);
    }

    function getForkFromChainId(uint16 chainId) internal view returns (ActiveFork storage) {
        return activeForks[chainId];
    }

    function advanceTime(uint256 _seconds) internal virtual {
        timestamp += _seconds;
        vm.warp(timestamp);
        assertEq(block.timestamp, timestamp);
    }

    function setUp() public virtual override {
        super.setUp();

        switchToHub();
        tunnels[hubFork.chainId].setRegisteredSender(
            spokeFork.chainId,
            toWormholeFormat(address(tunnels[spokeFork.chainId])),
            toWormholeFormat(address(spokeFork.USDC))
        );
        switchToSpoke();
        tunnels[spokeFork.chainId].setRegisteredSender(
            hubFork.chainId,
            toWormholeFormat(address(tunnels[hubFork.chainId])),
            toWormholeFormat(address(hubFork.USDC))
        );
    }

    function forkIdToChainId(uint256 _forkId) internal view returns (uint16) {
        return activeForksList[_forkId];
    }

    function deliverMessages() public {
        deliverMessages(new Vm.Log[](0));
    }

    function deliverMessages(Vm.Log[] memory logs) public {
        tunnels[forkIdToChainId(vm.activeFork())].deliverMessages();
        if (logs.length == 0) {
            logs = vm.getRecordedLogs();
        }
        relay(logs);

        assertEq(block.timestamp, timestamp);
    }

    // copied and adapted from MockOffChainRelayer to sidestep time issues when switching forks
    function relay(Vm.Log[] memory logs) public {
        uint16 chainIdOfWormholeAndGuardianUtilities = spokeFork.chainId;
        ActiveFork storage guardianFork = getForkFromChainId(chainIdOfWormholeAndGuardianUtilities);
        IWormhole relayerWormhole = guardianFork.wormhole;
        WormholeSimulator relayerWormholeSimulator = guardianFork.guardian;
        CircleMessageTransmitterSimulator relayerCircleSimulator = guardianFork.circleAttester;

        uint16 chainId = forkIdToChainId(vm.activeFork());
        switchToChain(chainIdOfWormholeAndGuardianUtilities);

        Vm.Log[] memory entries = relayerWormholeSimulator
            .fetchWormholeMessageFromLog(logs);

        bytes[] memory encodedSignedVaas = new bytes[](entries.length);
        for (uint256 i = 0; i < encodedSignedVaas.length; i++) {
            encodedSignedVaas[i] = relayerWormholeSimulator.fetchSignedMessageFromLogs(
                entries[i],
                chainId
            );
        }

        bool checkCCTP = relayerCircleSimulator.valid();
        Vm.Log[] memory cctpEntries = new Vm.Log[](0);
        if(checkCCTP) {
            cctpEntries = relayerCircleSimulator
            .fetchMessageTransmitterLogsFromLogs(logs);
        }

        CCTPMessageLib.CCTPMessage[] memory circleSignedMessages = new CCTPMessageLib.CCTPMessage[](cctpEntries.length);
        for (uint256 i = 0; i < cctpEntries.length; i++) {
            circleSignedMessages[i] = relayerCircleSimulator.fetchSignedMessageFromLog(
                cctpEntries[i]
            );
        }

        IWormhole.VM[] memory parsed = new IWormhole.VM[](encodedSignedVaas.length);
        for (uint16 i = 0; i < encodedSignedVaas.length; i++) {
            parsed[i] = relayerWormhole.parseVM(encodedSignedVaas[i]);
        }
        for (uint16 i = 0; i < encodedSignedVaas.length; i++) {
            address targetRelayer = address(getForkFromChainId(chainId).relayer);

            if (
                parsed[i].emitterAddress ==
                toWormholeFormat(targetRelayer) &&
                (parsed[i].emitterChainId == chainId)
            ) {
                switchToChain(chainIdOfWormholeAndGuardianUtilities);
                genericRelay(
                    encodedSignedVaas[i],
                    encodedSignedVaas,
                    circleSignedMessages,
                    parsed[i]
                );
            }
        }

        switchToChain(chainId); // back to the original chain
    }

    function genericRelay(
        bytes memory encodedDeliveryVAA,
        bytes[] memory encodedSignedVaas,
        CCTPMessageLib.CCTPMessage[] memory cctpMessages,
        IWormhole.VM memory parsedDeliveryVAA
    ) internal {
        IWormhole relayerWormhole = spokeFork.wormhole;

        (uint8 payloadId, ) = parsedDeliveryVAA.payload.asUint8Unchecked(0);
        if (payloadId == 1) {
            DeliveryInstruction memory instruction = decodeDeliveryInstruction(
                parsedDeliveryVAA.payload
            );

            bytes[] memory encodedSignedVaasToBeDelivered = new bytes[](
                instruction.messageKeys.length
            );

            for (uint8 i = 0; i < instruction.messageKeys.length; i++) {
                if (instruction.messageKeys[i].keyType == 1) {
                    // VaaKey
                    (VaaKey memory vaaKey, ) = decodeVaaKey(
                        instruction.messageKeys[i].encodedKey,
                        0
                    );
                    for (uint8 j = 0; j < encodedSignedVaas.length; j++) {
                        if (vaaKeyMatchesVAA(vaaKey, encodedSignedVaas[j])) {
                            encodedSignedVaasToBeDelivered[i] = encodedSignedVaas[j];
                            break;
                        }
                    }
                } else if (instruction.messageKeys[i].keyType == 2) {
                    // CCTP Key
                    (CCTPMessageLib.CCTPKey memory key,) = decodeCCTPKey(instruction.messageKeys[i].encodedKey, 0);
                    for (uint8 j = 0; j < cctpMessages.length; j++) {
                        if (cctpKeyMatchesCCTPMessage(key, cctpMessages[j])) {
                            encodedSignedVaasToBeDelivered[i] = abi.encode(cctpMessages[j].message, cctpMessages[j].signature);
                            break;
                        }
                    }
                }
            }

            EvmExecutionInfoV1 memory executionInfo = decodeEvmExecutionInfoV1(
                instruction.encodedExecutionInfo
            );

            uint256 budget = executionInfo.gasLimit *
                executionInfo.targetChainRefundPerGasUnused +
                instruction.requestedReceiverValue +
                instruction.extraReceiverValue;

            uint16 targetChain = instruction.targetChain;

            switchToChain(targetChain);

            // this was a part of a separate MockOffchainRelayer
            // setting a limited budget made sense there, but it breaks the tests
            // budget was supposed to mimic how much ether the executing relayer EOA has
            // this can be unlimited for the purpose of the test suite
            //
            // vm.deal(address(this), budget);

            vm.recordLogs();
            IWormholeRelayerDelivery(getForkFromChainId(targetChain).relayer)
                .deliver{value: budget}(
                encodedSignedVaasToBeDelivered,
                encodedDeliveryVAA,
                payable(address(this)),
                bytes("")
            );

            setInfo(
                parsedDeliveryVAA.emitterChainId,
                parsedDeliveryVAA.sequence,
                encodedSignedVaasToBeDelivered,
                encodedDeliveryVAA
            );
        } else if (payloadId == 2) {
            RedeliveryInstruction
                memory instruction = decodeRedeliveryInstruction(
                    parsedDeliveryVAA.payload
                );

            DeliveryOverride memory deliveryOverride = DeliveryOverride({
                newExecutionInfo: instruction.newEncodedExecutionInfo,
                newReceiverValue: instruction.newRequestedReceiverValue,
                redeliveryHash: parsedDeliveryVAA.hash
            });

            EvmExecutionInfoV1 memory executionInfo = decodeEvmExecutionInfoV1(
                instruction.newEncodedExecutionInfo
            );
            uint256 budget = executionInfo.gasLimit *
                executionInfo.targetChainRefundPerGasUnused +
                instruction.newRequestedReceiverValue;

            bytes memory oldEncodedDeliveryVAA = getPastDeliveryVAA(
                instruction.deliveryVaaKey.chainId,
                instruction.deliveryVaaKey.sequence
            );
            bytes[] memory oldEncodedSignedVaas = getPastEncodedSignedVaas(
                instruction.deliveryVaaKey.chainId,
                instruction.deliveryVaaKey.sequence
            );

            uint16 targetChain = decodeDeliveryInstruction(
                relayerWormhole.parseVM(oldEncodedDeliveryVAA).payload
            ).targetChain;

            switchToChain(targetChain);
            IWormholeRelayerDelivery(getForkFromChainId(targetChain).relayer)
                .deliver{value: budget}(
                oldEncodedSignedVaas,
                oldEncodedDeliveryVAA,
                payable(address(this)),
                encode(deliveryOverride)
            );
        }
    }

    function vaaKeyMatchesVAA(
        VaaKey memory vaaKey,
        bytes memory signedVaa
    ) internal view returns (bool) {
        IWormhole relayerWormhole = spokeFork.wormhole;

        IWormhole.VM memory parsedVaa = relayerWormhole.parseVM(signedVaa);
        return
            (vaaKey.chainId == parsedVaa.emitterChainId) &&
            (vaaKey.emitterAddress == parsedVaa.emitterAddress) &&
            (vaaKey.sequence == parsedVaa.sequence);
    }

    function cctpKeyMatchesCCTPMessage(
        CCTPMessageLib.CCTPKey memory cctpKey,
        CCTPMessageLib.CCTPMessage memory cctpMessage
    ) internal pure returns (bool) {
        (uint64 nonce,) = cctpMessage.message.asUint64(12);
        (uint32 domain,) = cctpMessage.message.asUint32(4);
        return
           nonce == cctpKey.nonce && domain == cctpKey.domain;
    }

    function setInfo(
        uint16 chainId,
        uint64 deliveryVAASequence,
        bytes[] memory encodedSignedVaas,
        bytes memory encodedDeliveryVAA
    ) internal {
        bytes32 key = keccak256(abi.encodePacked(chainId, deliveryVAASequence));
        pastEncodedSignedVaas[key] = encodedSignedVaas;
        pastEncodedDeliveryVAA[key] = encodedDeliveryVAA;
    }

    function getPastEncodedSignedVaas(
        uint16 chainId,
        uint64 deliveryVAASequence
    ) public view returns (bytes[] memory) {
        return
            pastEncodedSignedVaas[
                keccak256(abi.encodePacked(chainId, deliveryVAASequence))
            ];
    }

    function getPastDeliveryVAA(
        uint16 chainId,
        uint64 deliveryVAASequence
    ) public view returns (bytes memory) {
        return
            pastEncodedDeliveryVAA[
                keccak256(abi.encodePacked(chainId, deliveryVAASequence))
            ];
    }
}