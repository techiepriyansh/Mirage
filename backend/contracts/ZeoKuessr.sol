// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";

address constant ROFL_EMULATOR = 0x2d774148fD9Bf280e09BA039ACFaD14a235B66F5;

uint256 constant OP_GET_GEO_LOCATION_IMAGE = 1; // getGeoLocationImage(locationSeed bytes)
uint256 constant OP_CALC_POOL_PARTITION = 2; // calcPoolPartition(gameId uint256, locationSeed bytes, numUser uint256, userGuesses bytes32[], userAmounts uint256[])

struct OffchainTx {
    uint256 id;
    uint256 gameId;
    uint256 op;
    bytes[] args;
}

struct UserState {
    uint256 guess;
    uint256 amount;
}

struct GameState {
    uint256 gameId;
    bytes locationSeed;
    uint256 poolAmount;
    uint256 numUsers;
    address[] userAddresses;
    bytes32[] userGuesses;
    uint256[] userAmounts;
    bool isEnded;
    bool isResolved;
}

contract ZeoKuessr {
    mapping(uint256 => GameState) private gameStates;
    uint256 private gameIdEnd = 1;

    mapping(uint256 => OffchainTx) private offchainTxs;

    uint256 private txIdStart = 1;
    uint256 private txIdEnd = 1;

    event NewGameCreated(uint256 indexed gameId);
    event GameStarted(uint256 indexed gameId);
    event GameEnded(uint256 indexed gameId);

    event GeoLocationImageResponse(uint256 indexed gameId, string imageId);
    event GamePoolPartitioned(uint256 indexed gameId);


    function callOffchain(uint256 gameId, uint256 op, bytes[] memory args) internal {
        uint256 txId = txIdEnd++;
        OffchainTx memory offchainTx = OffchainTx(txId, gameId, op, args);
        offchainTxs[txId] = offchainTx;
    }

    function getFirstPendingOffchainTx() external view returns (OffchainTx memory) {
        if (msg.sender != ROFL_EMULATOR) {
            revert("access restricted to the ROFL");
        }

        if (txIdStart == txIdEnd) {
            return OffchainTx(0, 0, 0, new bytes[](0));
        }
        return offchainTxs[txIdStart];
    }

    function bytesToUint256(bytes memory b) public pure returns (uint256) {
        require(b.length == 32, "Bytes length must be 32");
        uint256 output;
        assembly {
            output := mload(add(b, 32))
        }
        return output;
    }

    function sendResultFromOffchain(uint256 txId, bytes[] memory result) external {
        if (msg.sender != ROFL_EMULATOR) {
            revert("access restricted to the ROFL");
        }

        require(txId == txIdStart, "txId does not match the first pending tx");
        OffchainTx memory offchainTx = offchainTxs[txId];
        if (offchainTx.op == OP_GET_GEO_LOCATION_IMAGE) {
            // (imageId string)
            emit GeoLocationImageResponse(offchainTx.gameId, string(result[0]));
        } else if (offchainTx.op == OP_CALC_POOL_PARTITION) {
            // (gameId uint256, uint256[] partitionAmounts)
            GameState memory game = gameStates[offchainTx.gameId];
            for (uint256 i = 0; i < game.userAddresses.length; i++) {
                payable(game.userAddresses[i]).transfer(bytesToUint256(result[i]));
            }
        }
        delete offchainTxs[txId];
        txIdStart++;
    }

    function genRandLocationSeed() internal view returns (bytes memory) {
        bytes memory seed = Sapphire.randomBytes(32, "");
        return seed;
    }

    function getRandGeoLocation(uint256 gameId, bytes memory locationSeed) internal {
        bytes[] memory args = new bytes[](1);
        args[0] = locationSeed;
        callOffchain(gameId, OP_GET_GEO_LOCATION_IMAGE, args);
    }

    function calcPoolPartition(uint256 gameId, bytes memory locationSeed, uint256 numUsers, bytes32[] memory userGuesses, uint256[] memory userAmounts) internal {
        bytes[] memory args = new bytes[](4);
        args[0] = locationSeed;
        args[1] = abi.encodePacked(numUsers);
        args[2] = abi.encodePacked(userGuesses);
        args[3] = abi.encodePacked(userAmounts);
        callOffchain(gameId, OP_CALC_POOL_PARTITION, args);
    }

    function startGame(uint256 gameId) external {
        bytes memory locationSeed = genRandLocationSeed();
        gameStates[gameId].locationSeed = locationSeed;
        getRandGeoLocation(gameId, locationSeed);
        emit GameStarted(gameId);
    }

    function newGame() external {
        uint256 gameId = gameIdEnd++;
        gameStates[gameId] = GameState(
            gameId,
            new bytes(0),
            0,
            0,
            new address[](0),
            new bytes32[](0), // lat long encoded as bytes32
            new uint256[](0),
            false,
            false
        );
        emit NewGameCreated(gameId);
    }

    function joinGame(uint256 gameId) external {
        gameStates[gameId].userAddresses.push(msg.sender);
        gameStates[gameId].userGuesses.push("");
        gameStates[gameId].userAmounts.push(0);
    }

    function getUserIndex(uint256 gameId, address userAddress) internal view returns (uint256) {
        for (uint256 i = 0; i < gameStates[gameId].userAddresses.length; i++) {
            if (gameStates[gameId].userAddresses[i] == userAddress) {
                return i;
            }
        }
        return 99;
    }

    function guess(uint256 gameId, bytes32 userGuess) external payable {
        uint256 userIndex = getUserIndex(gameId, msg.sender);
        gameStates[gameId].userGuesses[userIndex] = userGuess;
        gameStates[gameId].numUsers++;
        gameStates[gameId].poolAmount += msg.value;
        gameStates[gameId].userAmounts[userIndex] = msg.value;
    }

    function endGame(uint256 gameId) external {
        require(gameStates[gameId].isEnded == false, "game already ended");
        require(getUserIndex(gameId, msg.sender) != 99, "not a player");

        GameState memory game = gameStates[gameId];
        calcPoolPartition(gameId, game.locationSeed, game.numUsers, game.userGuesses, game.userAmounts);

        gameStates[gameId].isEnded = true;
        gameStates[gameId].isResolved = false;
        emit GameEnded(gameId);
    }
}
