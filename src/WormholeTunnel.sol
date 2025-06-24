// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IWormhole} from "./interfaces/IWormhole.sol";
import {ITokenBridge} from "./interfaces/ITokenBridge.sol";
import {IWormholeRelayer} from "./interfaces/IWormholeRelayer.sol";
import {IMessageTransmitter} from "./interfaces/CCTPInterfaces/IMessageTransmitter.sol";
import {ITokenMessenger} from "./interfaces/CCTPInterfaces/ITokenMessenger.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenBridgeUtilities} from "./TokenBridgeUtilities.sol";
import {IWormholeTunnel} from "./interfaces/IWormholeTunnel.sol";
import "./Utils.sol";
import "./testing/helpers/ExecutionParameters.sol";

contract WormholeTunnel is IWormholeTunnel, Initializable, PausableUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;


    // https://docs.wormhole.com/wormhole/reference/constants#consistency-levels
    uint8 internal constant CONSISTENCY_LEVEL_FINALIZED = 15; // arbitrary number other than defined for instant or safe
    uint8 internal constant CONSISTENCY_LEVEL_SAFE = 201; // if network supports safe, then it's always 201
    uint8 internal constant CONSISTENCY_LEVEL_INSTANT = 200; // if network supports instant, then it's always 200

    // VAA_KEY_TYPE = 1 is already defined in IWormholeRelayer, which is imported.
    uint8 constant CCTP_KEY_TYPE = 2;

    uint256 public constant GAS_USAGE_WITH_TOKEN = 450_000;
    uint256 public constant GAS_USAGE_WITHOUT_TOKEN = 60_000;

    struct TunnelEnd {
        bytes32 tunnelEndAddress; // the WH format address of the other end of the tunnel
        bytes32 cctpUSDC; // the WH format address of the USDC contract on the other end of the tunnel
        bytes32 cctpRecipient; // the address that is going to be the CCTP recipient on that end. defaults to tunnelEndAddress with possible overrides.
        bytes32 cctpDestinationCaller; // the address that is going to call the CCTP receive function. defaults to tunnelEndAddress with possible overrides.

        uint256[20] __gap;
    }

    struct SendParams {
        uint16 chainId;
        bytes32 targetAddress;
        bytes encodedPayload;
        uint256 receiverValue;
        uint256 paymentForExtraReceiverValue;
        bytes executionParams;
        bytes32 refundRecipient;
        MessageKey[] tokenTransfers;
        uint8 consistencyLevel;
        uint256 valueToSend;
    }

    IWormhole public wormhole;
    ITokenBridge public tokenBridge;
    IWormholeRelayer standardRelayer;
    mapping(uint16 => IWormholeRelayer) customRelayers;
    IMessageTransmitter public circleMessageTransmitter;
    ITokenMessenger public circleTokenMessenger;
    IERC20 public USDC;
    mapping (uint16 => TunnelEnd) public tunnels;
    mapping (bytes32 => bool) public replayProtection;
    mapping(uint16 => uint32) public chainIdToCCTPDomain;

    modifier onlyWormholeRelayer(uint16 sourceChainId) {
        if (msg.sender != address(getRelayer(sourceChainId))) {
            revert OnlyWormholeRelayer();
        }
        _;
    }

    modifier onlyRegisteredSender(uint16 _chainId, bytes32 _sender) {
        if (tunnels[_chainId].tunnelEndAddress != _sender) {
            revert TunnelEndNotRegistered();
        }
        _;
    }

    modifier replayProtect(bytes32 deliveryHash) {
        if (replayProtection[deliveryHash]) {
            revert ReplayProtection();
        }
        replayProtection[deliveryHash] = true;
        _;
    }

    /**
     * @notice prevent initialize() from being invoked on the implementation contract
     */
    constructor() {
        _disableInitializers();
    }

    function initialize(
        IWormhole _wormhole,
        ITokenBridge _tokenBridge,
        IWormholeRelayer _wormholeRelayer,
        IMessageTransmitter _circleMessageTransmitter,
        ITokenMessenger _circleTokenMessenger,
        IERC20 _USDC
    ) public initializer {
        OwnableUpgradeable.__Ownable_init(msg.sender);
        PausableUpgradeable.__Pausable_init();
        wormhole = _wormhole;
        tokenBridge = _tokenBridge;
        standardRelayer = _wormholeRelayer;

        setupCCTP(_circleMessageTransmitter, _circleTokenMessenger, _USDC);

        setCCTPDomain(2, 0);
        setCCTPDomain(6, 1);
        setCCTPDomain(24, 2);
        setCCTPDomain(23, 3);
        setCCTPDomain(30, 6);
        setCCTPDomain(1, 5);
    }

    // setter for EVM chains where CCTP recipient can just be the other tunnel end
    function setRegisteredSender(uint16 _chainId, bytes32 _sender, bytes32 _usdc) external onlyOwner {
        setRegisteredSender(_chainId, _sender, _usdc, _sender, _sender);
    }

    // setter for some non-EVM chains (Solana) where the CCTP minter is a different address than the tunnel end
    function setRegisteredSender(uint16 _chainId, bytes32 _sender, bytes32 _usdc, bytes32 _cctpRecipient, bytes32 _cctpDestinationCaller) public onlyOwner {
        tunnels[_chainId].tunnelEndAddress = _sender;
        tunnels[_chainId].cctpUSDC = _usdc;
        tunnels[_chainId].cctpRecipient = _cctpRecipient;
        tunnels[_chainId].cctpDestinationCaller = _cctpDestinationCaller;
        emit TunnelEndRegistered(_chainId, _sender, _usdc != bytes32(0));
    }

    function setupCCTP(
        IMessageTransmitter _circleMessageTransmitter,
        ITokenMessenger _circleTokenMessenger,
        IERC20 _USDC
    ) public onlyOwner {
        bool allZero = address(_circleMessageTransmitter) == address(0) && address(_circleTokenMessenger) == address(0) && address(_USDC) == address(0);
        bool allNonZero = address(_circleMessageTransmitter) != address(0) && address(_circleTokenMessenger) != address(0) && address(_USDC) != address(0);
        if (!allZero && !allNonZero) {
            // can either set all or unset all
            revert InvalidCCTPConfig();
        }
        circleMessageTransmitter = _circleMessageTransmitter;
        circleTokenMessenger = _circleTokenMessenger;
        USDC = _USDC;
        emit CCTPConfigChanged(address(circleMessageTransmitter), address(circleTokenMessenger), address(USDC));
    }

    function setCustomRelayer(uint16 _chainId, IWormholeRelayer _relayer) external onlyOwner {
        // passing IWormholeRelayer(address(0)) resets the custom relayer to the WH standard relayer
        customRelayers[_chainId] = _relayer;
        emit CustomRelayerSet(_chainId, _relayer);
    }

    /**
     * Sets the CCTP Domain corresponding to chain 'chain' to be 'cctpDomain'
     * So that transfers of USDC to chain 'chain' use the target CCTP domain 'cctpDomain'
     *
     * Currently, cctp domains are:
     * Ethereum: Wormhole chain id 2, cctp domain 0
     * Avalanche: Wormhole chain id 6, cctp domain 1
     * Optimism: Wormhole chain id 24, cctp domain 2
     * Arbitrum: Wormhole chain id 23, cctp domain 3
     * Base: Wormhole chain id 30, cctp domain 6
     *
     * These can be set via:
     * setCCTPDomain(2, 0);
     * setCCTPDomain(6, 1);
     * setCCTPDomain(24, 2);
     * setCCTPDomain(23, 3);
     * setCCTPDomain(30, 6);
     */
    function setCCTPDomain(uint16 chain, uint32 cctpDomain) public onlyOwner {
        chainIdToCCTPDomain[chain] = cctpDomain;
    }

    function getCCTPDomain(uint16 chain) internal view returns (uint32) {
        return chainIdToCCTPDomain[chain];
    }

    function chainId() public view override returns (uint16) {
        return wormhole.chainId();
    }

    function isEvm(uint16 _chainId) public view override returns (bool) {
        uint256 tunnelEndUint = uint256(tunnels[_chainId].tunnelEndAddress);
        if (tunnelEndUint == 0) {
            revert TunnelEndNotRegistered();
        }

        uint256 usdcUint = uint256(tunnels[_chainId].cctpUSDC);
        // checks if both the tunnel address and USDC address are 20 bytes in length
        // the probability of a non-EVM chain randomly passing as EVM is
        // 1. 2^20/2^32 * 2^20/2^32 = 2^(-24) = 0.00000596046% for chains supporting CCTP
        // 2. 2^20/2^32 = 2^(-12) = 0.0244140625% for chains not supporting CCTP
        return tunnelEndUint >> 160 == 0 && usdcUint >> 160 == 0;
    }

    function isValidAmount(IERC20 token, uint256 amount) public view returns (bool) {
        if (token == USDC && supportsCCTP()) {
            return true;
        }

        return TokenBridgeUtilities.trimDust(amount, address(token)) == amount;
    }

    function sendEvmMessage(
        TunnelMessage memory message,
        uint256 gasLimit
    ) external payable {
        sendMessage(message, getEncodedEvmExecutionParams(gasLimit));
    }

    function sendMessage(
        TunnelMessage calldata _message
    ) external payable {
        sendMessage(_message, bytes(""));
    }

    function sendMessage(
        TunnelMessage memory message,
        bytes memory encodedExecutionParams
    ) public payable {
        if (message.token != bytes32(0)) {
            IERC20(fromWormholeFormat(message.token)).safeTransferFrom(msg.sender, address(this), message.amount);
        }

        // set the source chainId and sender
        message.source.chainId = chainId();
        message.source.sender = toWormholeFormat(msg.sender);

        _sendMessage(message, encodedExecutionParams, msg.value);
    }

    function _sendMessage(
        TunnelMessage memory message,
        bytes memory encodedExecutionParams,
        uint256 msgValue
    ) internal virtual whenNotPaused {
        if (tunnels[message.target.chainId].tunnelEndAddress == bytes32(0)) {
            revert TunnelEndNotRegistered();
        }

        if (message.target.chainId == chainId()) {
            revert SameChainCallsNotSupported();
        }

        SendParams memory sendParams;
        sendParams.valueToSend = msgValue;

        // this fee covers sending the tokens through TokenBridge
        // CCTP transfers are free
        // we need to track all paid fees to be able to pass the remaining msg.value further downstream
        uint256 feesPaid = 0;
        if (message.token != bytes32(0)) {
            (sendParams.tokenTransfers, feesPaid) = handleTokenSend(message.target.chainId, IERC20(fromWormholeFormat(message.token)), message.amount);
            sendParams.valueToSend -= feesPaid;
        } else {
            sendParams.tokenTransfers = new MessageKey[](0);
        }

        // this computes the message execution cost on target. includes:
        // - WH costs
        // - the cost of gas on target (decode message, execute contract call, etc)
        // - the cost of passing receiverValue to target (if non-zero). receiverValue is in target chain native unit. cost is in source chain native unit.
        uint256 cost = getMessageCost(message.target.chainId, encodedExecutionParams, message.receiverValue, message.token != bytes32(0));
        if (msgValue < cost) {
            revert InsufficientMsgValue();
        }

        sendParams.paymentForExtraReceiverValue = msgValue - cost; // additional value sent in sending chain native currency
        sendParams.chainId = message.target.chainId;
        sendParams.targetAddress = tunnels[message.target.chainId].tunnelEndAddress; // the recipient of the message is the other end of the tunnel
        sendParams.encodedPayload = abi.encode(message);
        sendParams.receiverValue = message.receiverValue; // receiverValue in receiving chain native currency
        sendParams.executionParams = encodedExecutionParams;
        sendParams.refundRecipient = message.source.refundRecipient; // TODO: handle smart contract senders not getting gas refunds
        sendParams.consistencyLevel = getConsistencyLevelFromFinality(message.finality);

        // SendParams and _sendRaw were neccessary, because calling send() directly caused stack too deep compiler errors
        _sendRaw(sendParams);
    }

    function _sendRaw(SendParams memory sendParams) private {
        IWormholeRelayer wormholeRelayer = getRelayer(sendParams.chainId);
        wormholeRelayer.send{value: sendParams.valueToSend}(
            sendParams.chainId,
            sendParams.targetAddress,
            sendParams.encodedPayload,
            sendParams.receiverValue,
            sendParams.paymentForExtraReceiverValue,
            sendParams.executionParams,
            sendParams.chainId,
            sendParams.refundRecipient,
            wormholeRelayer.getDefaultDeliveryProvider(),
            sendParams.tokenTransfers,
            sendParams.consistencyLevel
        );
    }

    function receiveWormholeMessages(
        bytes memory payload,
        bytes[] memory additionalVaas,
        bytes32 sourceAddress,
        uint16 sourceChain,
        bytes32 deliveryHash
    )
    external
    payable
    onlyWormholeRelayer(sourceChain)
    onlyRegisteredSender(sourceChain, sourceAddress)
    replayProtect(deliveryHash)
    {
        // message.token contains the bytes32 source chain address of the sent token (if any)
        TunnelMessage memory message = abi.decode(payload, (TunnelMessage));
        address recipientAddress = fromWormholeFormat(message.target.recipient);
        IERC20 token; // the resulting token on receiving chain (either bridged through TokenBridge or USDC through CCTP)
        if (message.token != bytes32(0) && additionalVaas.length > 0) {
            if (additionalVaas.length != 1) {
                revert InvalidTunnelMessage();
            }
            token = handleTokenReceive(sourceChain, message.token, message.amount, additionalVaas);
        } else if (message.token != bytes32(0) || additionalVaas.length > 0) {
            // either both or none should be present
            revert InvalidTunnelMessage();
        }

        bool success;
        bytes memory ret;
        if (message.target.selector == bytes4(0)) {
            // send the tokens to the specified recipient
            if (token != IERC20(address(0))) {
                token.safeTransfer(recipientAddress, message.amount);
                success = true;
            }
            // check if msg.value is enough to cover the receiverValue
            if (message.receiverValue > 0 && msg.value < message.receiverValue) {
                revert InsufficientMsgValue();
            }

            // send any received ETH to the recipient
            (success, ret) = payable(recipientAddress).call{value: msg.value}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            // this is a contract call
            if (token != IERC20(address(0))) {
                token.forceApprove(recipientAddress, message.amount);
            }
            (success, ret) = recipientAddress.call{value: msg.value}(
                abi.encodeWithSelector(
                    message.target.selector,
                    message.source,
                    token,
                    message.amount,
                    message.target.payload
                )
            );
        }

        if (!success) {
            emit TargetReverted(ret);
            // send tokens and ETH back to the sender
            _sendMessage(
                TunnelMessage({
                    source: MessageSource({
                        chainId: chainId(),
                        sender: toWormholeFormat(address(this)),
                        refundRecipient: message.source.refundRecipient
                    }),
                    target: MessageTarget({
                        chainId: message.source.chainId,
                        recipient: message.source.refundRecipient,
                        selector: bytes4(0),
                        payload: bytes("")
                    }),
                    token: toWormholeFormat(address(token)),
                    amount: message.amount,
                    receiverValue: 0,
                    finality: MessageFinality.FINALIZED
                }),
                getEncodedExecutionParams(message.source.chainId, address(token) != address(0)),
                msg.value
            );
        }
    }

    function getMessageCost(uint16 _targetChain, uint256 _gasLimitOnTarget, uint256 _receiverValue, bool _withTokenTransfer) public view returns (uint256 cost) {
        return getMessageCost(_targetChain, getEncodedEvmExecutionParams(_gasLimitOnTarget), _receiverValue, _withTokenTransfer);
    }

    function getMessageCost(uint16 _targetChain, bytes memory _encodedExecutionParams, uint256 _receiverValue, bool _withTokenTransfer) public view returns (uint256 cost) {
        uint256 msgFee = wormhole.messageFee();

        IWormholeRelayer wormholeRelayer = getRelayer(_targetChain);

        (uint256 deliveryCost,) = wormholeRelayer.quoteDeliveryPrice(
            _targetChain,
            _receiverValue,
            _encodedExecutionParams,
            wormholeRelayer.getDefaultDeliveryProvider()
        );

        cost = msgFee + deliveryCost;
        if (_withTokenTransfer) {
            cost += msgFee;
        }
        return cost;
    }

    function supportsCCTP() public view returns (bool) {
        // it's enough to check this, because either all CCTP addresses are zero or none are
        return circleMessageTransmitter != IMessageTransmitter(address(0));
    }

    function tunnelEndSupportsCCTP(uint16 _chainId) public view returns (bool) {
        return tunnels[_chainId].cctpUSDC != bytes32(0);
    }

    function getTokenAddressOnThisChain(uint16 tokenHomeChain, bytes32 tokenHomeAddress)
        public
        view
        returns (address tokenAddressOnThisChain)
    {
        if (tokenHomeChain == chainId()) {
            // token native to this chain
            return fromWormholeFormat(tokenHomeAddress);
        }

        if (tunnelEndSupportsCCTP(tokenHomeChain) && tokenHomeAddress == tunnels[tokenHomeChain].cctpUSDC) {
            // CCTP USDC
            return address(USDC);
        }

        // bridged token
        return tokenBridge.wrappedAsset(tokenHomeChain, tokenHomeAddress);
    }

    function getRelayer(uint16 _chainId) public view returns (IWormholeRelayer) {
        if (customRelayers[_chainId] != IWormholeRelayer(address(0))) {
            return customRelayers[_chainId];
        }

        return standardRelayer;
    }

    function getEncodedEvmExecutionParams(uint256 _gasLimit) internal pure returns (bytes memory) {
        EvmExecutionParamsV1 memory params = getEmptyEvmExecutionParamsV1();
        params.gasLimit = _gasLimit;
        return encodeEvmExecutionParamsV1(params);
    }

    function getEncodedExecutionParams(uint16 /*_targetChain*/, bool _withTokenTransfer) internal pure returns (bytes memory) {
        // TODO: switch based on _targetChain and support non-EVM execution params
        return getEncodedEvmExecutionParams(_withTokenTransfer ? GAS_USAGE_WITH_TOKEN : GAS_USAGE_WITHOUT_TOKEN);
    }

    function getConsistencyLevelFromFinality(MessageFinality finality) internal pure returns (uint8) {
        if (finality == MessageFinality.INSTANT) {
            return CONSISTENCY_LEVEL_INSTANT;
        } else if (finality == MessageFinality.SAFE) {
            return CONSISTENCY_LEVEL_SAFE;
        } else {
            return CONSISTENCY_LEVEL_FINALIZED;
        }
    }

    function handleTokenSend(uint16 targetChain, IERC20 token, uint256 amount) internal returns (MessageKey[] memory messageKeys, uint256 feesPaid) {
        messageKeys = new MessageKey[](1);
        // this tunnel end supporting CCTP is implied here, because token is non-zero and USDC is only non-zero if CCTP is supported
        if (address(token) == address(USDC) && tunnelEndSupportsCCTP(targetChain)) {
            // sending USDC via CCTP
            token.forceApprove(address(circleTokenMessenger), amount);
            uint64 nonce = circleTokenMessenger.depositForBurnWithCaller(
                amount,
                getCCTPDomain(targetChain),
                tunnels[targetChain].cctpRecipient,
                address(token),
                tunnels[targetChain].cctpDestinationCaller
            );
            messageKeys[0] = MessageKey({
                keyType: CCTP_KEY_TYPE,
                encodedKey: abi.encodePacked(getCCTPDomain(chainId()), nonce)
            });
        } else {
            token.forceApprove(address(tokenBridge), amount);
            uint256 msgFee = wormhole.messageFee();
            uint64 sequence = tokenBridge.transferTokensWithPayload{value: msgFee}(
                address(token),
                amount,
                targetChain,
                tunnels[targetChain].tunnelEndAddress, // sending to the other end of the tunnel
                0,
                bytes("") // no payload with token transfer // TODO: can we send here TunnelMessage, so that Solana spoke can receive only ona VAA ?
            );
            messageKeys[0] = MessageKey({
                keyType: VAA_KEY_TYPE,
                encodedKey: abi.encodePacked(chainId(), toWormholeFormat(address(tokenBridge)), sequence)
            });
            feesPaid = msgFee;
        }
    }

    function handleTokenReceive(uint16 sourceChain, bytes32 tokenAddress, uint256 amount, bytes[] memory additionalVaas) internal returns (IERC20) {
        // tokenAddress is the bytes32 address of the token on the chain that sent the message
        // this can be:
        // - the wrapped address for bridged tokens if the token was a WH bridged token that returns to this chain (getTokenAddressOnThisChain will return zero in this case only)
        // - the bytes32 address of the USDC contract on the source chain
        // - the bytes32 address of the token on the source chain
        // if getTokenAddressOnThisChain returns zero, the token address is taken from the TokenBridge transfer
        IERC20 token = IERC20(getTokenAddressOnThisChain(sourceChain, tokenAddress));
        TunnelEnd storage sender = tunnels[sourceChain];

        if (tunnelEndSupportsCCTP(sourceChain) && supportsCCTP() && tokenAddress == sender.cctpUSDC) {
            (bytes memory cctpMessage, bytes memory cctpSignature) = abi.decode(additionalVaas[0], (bytes, bytes));
            uint256 beforeBalance = USDC.balanceOf(address(this));
            circleMessageTransmitter.receiveMessage(cctpMessage, cctpSignature);
            if (amount != USDC.balanceOf(address(this)) - beforeBalance) {
                revert InvalidTunnelMessage();
            }
            token = USDC;
        } else {
            IWormhole.VM memory parsed = wormhole.parseVM(additionalVaas[0]);
            if (parsed.emitterAddress != tokenBridge.bridgeContracts(parsed.emitterChainId)) {
                // guards against messages not emitted by WH on sender's end
                revert InvalidVaa();
            }
            ITokenBridge.TransferWithPayload memory transfer = tokenBridge.parseTransferWithPayload(parsed.payload);
            if (transfer.to != toWormholeFormat(address(this)) || transfer.toChain != chainId()) {
                // guards against valid messages not intended for this chain or recipient
                revert InvalidVaa();
            }

            if (token == IERC20(address(0))) {
                // could not determine token address from tokenHomeChain and tokenHomeAddress
                // this means this token is native to this chain
                // therefore it's an unwrap of the bridged token to the native token
                token = IERC20(fromWormholeFormat(transfer.tokenAddress));
            }

            tokenBridge.completeTransferWithPayload(additionalVaas[0]);

            if (amount != TokenBridgeUtilities.denormalizeAmount(transfer.amount, address(token))) {
                revert InvalidTunnelMessage();
            }
        }

        return token;
    }
}