// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWormholeRelayer} from "@wormhole/interfaces/IWormholeRelayer.sol";

interface IWormholeTunnel {
    error InsufficientMsgValue();
    error InvalidCCTPConfig();
    error InvalidTunnelMessage();
    error InvalidVaa();
    error OnlyWormholeRelayer();
    error ReplayProtection();
    error SameChainCallsNotSupported();
    error TransferFailed();
    error TunnelEndNotRegistered();

    event CCTPConfigChanged(address indexed messageTransmitter, address indexed tokenMessenger, address indexed usdc);
    event TunnelEndRegistered(uint16 indexed chainId, bytes32 indexed sender, bool supportsCCTP);
    event CustomRelayerSet(uint16 indexed chainId, IWormholeRelayer relayerAddress);
    event TargetReverted(bytes ret);

    enum MessageFinality {
        FINALIZED,
        SAFE,
        INSTANT
    }

    struct TunnelMessage {
        MessageSource source; // defines the sender of the message and the chain it's coming from
        MessageTarget target; // defines the recipient of the message and the chain it's going to
        bytes32 token; // the address of the token sent along with the message (optional)
        uint256 amount; // the amount of the token sent along with the message (optional)
        uint256 receiverValue; // the value that the message recipient is supposed to receive in target chain native currency (optional)
        MessageFinality finality; // the finality of the message
    }

    struct MessageSource {
        uint16 chainId; // the chain id of the sender
        bytes32 sender; // the address of the sender
        // the address that should receive any WH cost refunds on target chain.
        // in case the message recipient reverts and tokens were sent, the tokens will be returned to this address on source chain
        bytes32 refundRecipient;
    }

    struct MessageTarget {
        uint16 chainId; // the chain id of the recipient
        bytes32 recipient; // the address of the recipient of the message on the target chain
        bytes4 selector; // if the recipient is a contract, the selector of the function to call (optional)
        bytes payload; // if the recipient is a contract, the data to send to the function call (optional)
    }

    /**
     * @dev sends a message assuming the target chain is EVM
     * @param _message the message to send
     * @param _gasLimit the gas limit for the message
     */
    function sendEvmMessage(
        TunnelMessage calldata _message,
        uint256 _gasLimit
    ) external payable;

    /**
     * @dev sends a message providing no additional execution parameters (for gasless chains or custom relayers)
     * @param _message the message to send
     */
    function sendMessage(
        TunnelMessage calldata _message
    ) external payable;

    /**
     * @dev sends a message providing additional encoded execution parameters
     * @param _message the message to send
     * @param encodedExecutionParams the encoded execution parameters
     */
    function sendMessage(
        TunnelMessage calldata _message,
        bytes calldata encodedExecutionParams
    ) external payable;

    function USDC() external view returns (IERC20);

    /**
     * @dev whether this tunnel supports Circle's CCTP
     */
    function supportsCCTP() external view returns (bool);

    /**
     * @dev whether the tunnel end on a given chain supports Circle's CCTP
     */
    function tunnelEndSupportsCCTP(uint16 _chainId) external view returns (bool);

    /**
     * @dev the chain id of the tunnel
     */
    function chainId() external view returns (uint16);

    /**
     * @dev returns whether a given _chainId is EVM compatible
     */
    function isEvm(uint16 _chainId) external view returns (bool);

    /**
     * @dev the gas required for the tunnel to send a message with a token transfer
     *      this is on top of any gas required with cross chain contract calls and only covers what the tunnel uses
     */
    function GAS_USAGE_WITH_TOKEN() external view returns (uint256);


    /**
     * @dev the gas required for the tunnel to send a message without a token transfer
     *      same as above, but without the token transfer
     */
    function GAS_USAGE_WITHOUT_TOKEN() external view returns (uint256);

    /**
     * @dev gets the address of a token on the current chain
     *      handles both CCTP USDC translation and TokenBridge wrapped tokens (native addr -> wrapped addr)
     *      can't handle "unbridging" tokens (getting the original token asset from a bridged asset address)
     * @param tokenHomeChain the chain id of the token
     * @param tokenHomeAddress the address of the token on the home chain
     */
    function getTokenAddressOnThisChain(uint16 tokenHomeChain, bytes32 tokenHomeAddress) external view returns (address);

    /**
     * @dev gets the cost of sending a message
     * @param _targetChain the chain id of the target chain
     * @param _gasLimitOnTarget the gas limit for parsing and executing the message
     * @param _receiverValue the value that the message recipient is supposed to receive in target chain native currency
     * @param _withTokenTransfer whether the message includes a token transfer
     */
    function getMessageCost(uint16 _targetChain, uint256 _gasLimitOnTarget, uint256 _receiverValue, bool _withTokenTransfer) external view returns (uint256 cost);

    /**
     * @dev checks if an amount is valid for a token transfer. WH TokenBridge limits amounts to 8 decimals. USDC through CCTP is assumed ok.
     * @param token the address of the token
     * @param amount the amount to transfer
     */
    function isValidAmount(IERC20 token, uint256 amount) external view returns (bool);

    /**
     * @dev returns the address of the relayer that handles messages to and from chainId
     * @param chainId the WH chainId
     * @return IWormholeRelayer the relayer contract
     */
    function getRelayer(uint16 chainId) external view returns (IWormholeRelayer);
}
