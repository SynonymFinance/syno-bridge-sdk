// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IWormholeTunnel, WormholeTunnel, IWormholeTunnel, IWormhole, ITokenBridge, IWormholeRelayer, IMessageTransmitter, ITokenMessenger, IERC20} from "../WormholeTunnel.sol";

contract DelayingWormholeTunnel is WormholeTunnel {
    event DelayingMessage(uint256 currentTime, uint256 finalizationTime);
    event SentMessage(IWormholeTunnel.MessageFinality finality, uint256 currentTime);

    struct MessageWithDelay {
        TunnelMessage message;
        bytes encodedExecutionParams;
        uint256 msgValue;
        uint256 finalizationTime;
        bool sent;
    }

    uint256 public finalizationDelay;

    MessageWithDelay[] public delayedMessages;

    function setFinalizationDelay(uint256 _delay) public {
        finalizationDelay = _delay;
    }

    function _sendMessage(
        TunnelMessage memory _message,
        bytes memory _encodedExecutionParams,
        uint256 _msgValue
    ) internal override whenNotPaused {
        if (_message.finality == IWormholeTunnel.MessageFinality.FINALIZED && finalizationDelay > 0) {
            delayedMessages.push(MessageWithDelay({
                message: _message,
                encodedExecutionParams: _encodedExecutionParams,
                msgValue: _msgValue,
                finalizationTime: block.timestamp + finalizationDelay,
                sent: false
            }));
            emit DelayingMessage(block.timestamp, block.timestamp + finalizationDelay);
        } else {
            super._sendMessage(_message, _encodedExecutionParams, _msgValue);
            emit SentMessage(_message.finality, block.timestamp);
        }
    }

    function deliverMessages() public {
        for (uint256 i = 0; i < delayedMessages.length; i++) {
            if (block.timestamp >= delayedMessages[i].finalizationTime && !delayedMessages[i].sent) {
                super._sendMessage(
                    delayedMessages[i].message,
                    delayedMessages[i].encodedExecutionParams,
                    delayedMessages[i].msgValue
                );
                delayedMessages[i].sent = true;
                emit SentMessage(delayedMessages[i].message.finality, block.timestamp);
            }
        }
    }
}