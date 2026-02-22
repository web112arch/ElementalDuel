// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* ────────────────────────────────────────────────────────────────────────────
 *  External interfaces
 * ────────────────────────────────────────────────────────────────────────── */

interface IERC1155Minimal {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

interface IMana {
    function hasMana(address account, uint256 amount) external view returns (bool);
    function consumeMana(address account, uint256 amount) external;
}

interface IPoints {
    function mint(address account, uint256 amount) external;
}

interface IReward {
    function handleMatchResult(
        address winner,
        address loser,
        bool isDraw,
        uint256 roomId
    ) external;
}

/* ────────────────────────────────────────────────────────────────────────────
 *  1-v-1 Game contract (more secure V3)
 * ────────────────────────────────────────────────────────────────────────── */

import {Ownable2Step}    from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable}         from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";

contract ElementalDuel is Ownable2Step, ReentrancyGuard, Pausable {
    /* ─────────────  Configuration  ───────────── */

    uint256 public revealWindow;   // blocks to reveal after P2 joins
    uint256 public joinTimeout;    // blocks before user1 may solo-resolve (public rooms)

    uint256 public firstPassTokenId;
    uint256 public firstPassMultiplier;

    uint256 public businessPassTokenId;
    uint256 public businessPassMultiplier;

    uint256 public ecoPassTokenId;
    uint256 public ecoPassMultiplier;

    uint256 public basePoints = 100;

    IERC1155Minimal public nft;
    IERC1155Minimal public ticket;
    IMana           public mana;
    IPoints         public points;
    IReward         public reward;            // optional

    // cap reward gas to reduce DoS risk via heavy reward logic
    uint256 public rewardGasLimit = 150_000;  // you can tune

    constructor(
        address _nft,
        address _ticket,
        address _mana,
        address _points,
        address _reward,
        uint256 _revealWindow,
        uint256 _joinTimeout
    ) Ownable(msg.sender) {
        require(_nft != address(0) && _ticket != address(0) && _mana != address(0) && _points != address(0), "Zero addr");
        require(_revealWindow > 0 && _joinTimeout > 0, "Zero blocks");

        nft     = IERC1155Minimal(_nft);
        ticket  = IERC1155Minimal(_ticket);
        mana    = IMana(_mana);
        points  = IPoints(_points);
        reward  = IReward(_reward); // can be 0x0 to disable

        revealWindow = _revealWindow;
        joinTimeout  = _joinTimeout;

        // defaults
        firstPassTokenId = 3;  firstPassMultiplier = 5;
        businessPassTokenId = 2; businessPassMultiplier = 3;
        ecoPassTokenId = 1;   ecoPassMultiplier = 2;

        emit ConfigUpdated(_nft, _ticket, _mana, _points, _reward);
        emit TimeoutsUpdated(_revealWindow, _joinTimeout);
        emit RewardGasLimitUpdated(rewardGasLimit);
    }

    /* ─────────────  Data structures  ───────────── */

    enum RoomType { Public, Private }
    enum State    { WaitingForP2, Revealing, Finished }

    struct Room {
        address user1;
        address user2;

        bytes32 hash1;
        bytes32 hash2;

        uint256 token1;
        uint256 token2;
        bool    revealed1;
        bool    revealed2;

        uint40  createdBlock;
        uint40  p2JoinedBlock;
        uint40  firstRevealBlock;

        RoomType roomType;
        State   state;
    }

    uint256 public nextRoomId = 1;
    uint256 public openPublicRoomId; // 0 if none

    mapping(uint256 => Room) public rooms;
    mapping(address => uint256) private _activeRoomOf;

    error AlreadyOwnRoom(uint256 roomId);
    error NotParticipant();
    error InvalidState();
    error RevealStillActive();
    error InvalidTokenId();

    /* ─────────────  Events  ───────────── */

    event RoomCreated(uint256 indexed roomId, address indexed user1, RoomType roomType);
    event JoinedRoom (uint256 indexed roomId, address indexed user2);
    event Revealed   (uint256 indexed roomId, address indexed user, uint256 tokenId);

    event Resolved(
        uint256 indexed roomId,
        address winner,
        address loser,
        bool    isDraw,
        bool    isBothLose,
        uint256 p1TokenId,
        uint256 p2TokenId,
        bool    rewardCallFailed
    );

    event ConfigUpdated(address nft, address ticket, address mana, address points, address reward);
    event TimeoutsUpdated(uint256 revealWindow, uint256 joinTimeout);
    event BasePointsUpdated(uint256 basePoints);
    event PassConfigUpdated(uint256 firstId, uint256 firstMult, uint256 bizId, uint256 bizMult, uint256 ecoId, uint256 ecoMult);
    event RewardGasLimitUpdated(uint256 gasLimit);

    /* ─────────────  Modifiers  ───────────── */

    modifier onlyParticipant(uint256 roomId) {
        Room storage r = rooms[roomId];
        if (msg.sender != r.user1 && msg.sender != r.user2) revert NotParticipant();
        _;
    }

    /* ─────────────  Owner controls  ───────────── */

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function setNft(address _nft) external onlyOwner {
        require(_nft != address(0), "Zero address");
        nft = IERC1155Minimal(_nft);
        emit ConfigUpdated(_nft, address(ticket), address(mana), address(points), address(reward));
    }

    function setTicket(address _ticket) external onlyOwner {
        require(_ticket != address(0), "Zero address");
        ticket = IERC1155Minimal(_ticket);
        emit ConfigUpdated(address(nft), _ticket, address(mana), address(points), address(reward));
    }

    function setMana(address _mana) external onlyOwner {
        require(_mana != address(0), "Zero address");
        mana = IMana(_mana);
        emit ConfigUpdated(address(nft), address(ticket), _mana, address(points), address(reward));
    }

    function setPoints(address _points) external onlyOwner {
        require(_points != address(0), "Zero address");
        points = IPoints(_points);
        emit ConfigUpdated(address(nft), address(ticket), address(mana), _points, address(reward));
    }

    function setReward(address _reward) external onlyOwner {
        reward = IReward(_reward); // 0 disables
        emit ConfigUpdated(address(nft), address(ticket), address(mana), address(points), _reward);
    }

    function setRewardGasLimit(uint256 _gas) external onlyOwner {
        require(_gas >= 30_000 && _gas <= 500_000, "gas out of range");
        rewardGasLimit = _gas;
        emit RewardGasLimitUpdated(_gas);
    }

    function setRevealWindow(uint256 _revealWindow) external onlyOwner {
        require(_revealWindow > 0, "Zero blocks");
        revealWindow = _revealWindow;
        emit TimeoutsUpdated(_revealWindow, joinTimeout);
    }

    function setJoinTimeout(uint256 _joinTimeout) external onlyOwner {
        require(_joinTimeout > 0, "Zero blocks");
        joinTimeout = _joinTimeout;
        emit TimeoutsUpdated(revealWindow, _joinTimeout);
    }

    function setBasePoints(uint256 _basePoints) external onlyOwner {
        require(_basePoints > 0, "Base points must be > 0");
        basePoints = _basePoints;
        emit BasePointsUpdated(_basePoints);
    }

    function setFirstPassConfig(uint256 _tokenId, uint256 _multiplier) external onlyOwner {
        require(_multiplier > 0, "Multiplier must be > 0");
        firstPassTokenId = _tokenId;
        firstPassMultiplier = _multiplier;
        emit PassConfigUpdated(firstPassTokenId, firstPassMultiplier, businessPassTokenId, businessPassMultiplier, ecoPassTokenId, ecoPassMultiplier);
    }

    function setBusinessPassConfig(uint256 _tokenId, uint256 _multiplier) external onlyOwner {
        require(_multiplier > 0, "Multiplier must be > 0");
        businessPassTokenId = _tokenId;
        businessPassMultiplier = _multiplier;
        emit PassConfigUpdated(firstPassTokenId, firstPassMultiplier, businessPassTokenId, businessPassMultiplier, ecoPassTokenId, ecoPassMultiplier);
    }

    function setEcoPassConfig(uint256 _tokenId, uint256 _multiplier) external onlyOwner {
        require(_multiplier > 0, "Multiplier must be > 0");
        ecoPassTokenId = _tokenId;
        ecoPassMultiplier = _multiplier;
        emit PassConfigUpdated(firstPassTokenId, firstPassMultiplier, businessPassTokenId, businessPassMultiplier, ecoPassTokenId, ecoPassMultiplier);
    }

    /* ─────────────  Commitment helper  ─────────────
       Stronger domain separation:
       commitment must be:
       keccak256(abi.encode(
           address(this),
           block.chainid,
           playerAddress,
           tokenId,
           randomPhase
       ))
    */
    function computeCommitment(address player, uint256 tokenId, uint256 randomPhase)
        external
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(address(this), block.chainid, player, tokenId, randomPhase));
    }

    /* ─────────────  Public-room flow  ───────────── */

    function startGame(bytes32 commitment) external nonReentrant whenNotPaused {
        require(commitment != bytes32(0), "Zero commitment");
        require(mana.hasMana(msg.sender, 1), "No mana");
        if (_activeRoomOf[msg.sender] != 0) revert AlreadyOwnRoom(_activeRoomOf[msg.sender]);

        if (openPublicRoomId == 0) {
            uint256 roomId = _createRoom(msg.sender, commitment, RoomType.Public);
            openPublicRoomId = roomId;
            _activeRoomOf[msg.sender] = roomId;
        } else {
            uint256 roomId = openPublicRoomId;
            Room storage r = rooms[roomId];

            require(r.user1 != msg.sender, "Cannot join own room");
            require(r.state == State.WaitingForP2, "Room not joinable");

            r.user2         = msg.sender;
            r.hash2         = commitment;
            r.p2JoinedBlock = uint40(block.number);
            r.state         = State.Revealing;

            emit JoinedRoom(roomId, msg.sender);

            _activeRoomOf[msg.sender] = roomId;
            openPublicRoomId = 0;
        }
    }

    /* ──────────  Private-room helpers  ────────── */

    function createPrivateRoom(bytes32 commitment)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 roomId)
    {
        require(commitment != bytes32(0), "Zero commitment");
        require(mana.hasMana(msg.sender, 1), "No mana");
        if (_activeRoomOf[msg.sender] != 0) revert AlreadyOwnRoom(_activeRoomOf[msg.sender]);

        roomId = _createRoom(msg.sender, commitment, RoomType.Private);
        _activeRoomOf[msg.sender] = roomId;
    }

    function joinPrivateRoom(uint256 roomId, bytes32 commitment) external nonReentrant whenNotPaused {
        require(commitment != bytes32(0), "Zero commitment");
        Room storage r = rooms[roomId];

        require(r.user1 != address(0), "Room not found");
        require(r.roomType == RoomType.Private, "Not private");
        require(r.state == State.WaitingForP2,  "Already joined");
        require(r.user1 != msg.sender, "Cannot join own room");
        require(r.user2 == address(0), "Someone joined");
        require(mana.hasMana(msg.sender, 1), "No mana");
        require(_activeRoomOf[msg.sender] == 0, "Already in room");

        r.user2         = msg.sender;
        r.hash2         = commitment;
        r.p2JoinedBlock = uint40(block.number);
        r.state         = State.Revealing;

        emit JoinedRoom(roomId, msg.sender);

        _activeRoomOf[msg.sender] = roomId;
    }

    function cancelPrivateRoom(uint256 roomId) external nonReentrant whenNotPaused {
        Room storage r = rooms[roomId];
        require(r.user1 != address(0), "Room not found");
        require(msg.sender == r.user1, "Only owner can cancel");
        require(r.roomType == RoomType.Private, "Not private");
        require(r.state == State.WaitingForP2, "Cannot cancel");

        r.state = State.Finished;
        emit Resolved(roomId, address(0), address(0), false, false, 0, 0, false);
        _closeRoom(r, roomId);
    }

    /* ─────────────  Reveal & resolve  ───────────── */

    function reveal(uint256 roomId, uint256 tokenId, uint256 randomPhase)
        external
        onlyParticipant(roomId)
        nonReentrant
        whenNotPaused
    {
        // validate early to prevent griefing with invalid ids
        if (tokenId < 1 || tokenId > 25) revert InvalidTokenId();

        Room storage r = rooms[roomId];
        if (r.state != State.Revealing) revert InvalidState();

        require(block.number <= r.p2JoinedBlock + revealWindow, "Reveal window closed");

        // stronger domain separation in commitment
        bytes32 expectedHash = keccak256(abi.encode(address(this), block.chainid, msg.sender, tokenId, randomPhase));

        if (msg.sender == r.user1) {
            require(!r.revealed1, "Already revealed");
            require(expectedHash == r.hash1, "Invalid hash");
            r.token1    = tokenId;
            r.revealed1 = true;
        } else {
            require(!r.revealed2, "Already revealed");
            require(expectedHash == r.hash2, "Invalid hash");
            r.token2    = tokenId;
            r.revealed2 = true;
        }

        require(nft.balanceOf(msg.sender, tokenId) > 0, "Not owner of NFT");

        emit Revealed(roomId, msg.sender, tokenId);

        if (r.firstRevealBlock == 0) {
            r.firstRevealBlock = uint40(block.number);
        } else {
            _resolveMatch(roomId);
        }
    }

    function forceResolveMatch(uint256 roomId)
        external
        onlyParticipant(roomId)
        nonReentrant
        whenNotPaused
    {
        Room storage r = rooms[roomId];
        require(r.state == State.Revealing, "Not revealing");
        require(r.user1 != address(0) && r.user2 != address(0), "No players");
        require(block.number > r.p2JoinedBlock + revealWindow, "Too early");
        _resolveMatch(roomId);
    }

    function soloResolveMatch(uint256 roomId) external nonReentrant whenNotPaused {
        Room storage r = rooms[roomId];
        require(r.user1 != address(0), "Room not found");
        require(r.roomType == RoomType.Public, "Not public");
        require(r.state == State.WaitingForP2, "Not solo");
        require(msg.sender == r.user1, "Not room creator");
        require(r.user2 == address(0), "User2 joined");
        require(block.number > r.createdBlock + joinTimeout, "Too early");

        (address winner, address loser, bool isDraw) = _soloOutcome(r.user1);

        bool rewardFailed = _callReward(winner, loser, isDraw, roomId);

        if (winner != address(0)) {
            points.mint(winner, basePoints * _ticketMultiplier(winner));
        }
        if (loser != address(0)) {
            mana.consumeMana(loser, 1);
        }

        r.state = State.Finished;
        emit Resolved(roomId, winner, loser, isDraw, false, 0, 0, rewardFailed);

        _closeRoom(r, roomId);
        openPublicRoomId = 0;
    }

    function activeRoomOf(address player) external view returns (uint256) {
        return _activeRoomOf[player];
    }

    function _resolveMatch(uint256 roomId) internal {
        Room storage r = rooms[roomId];
        require(r.state != State.Finished, "Already resolved");
        require(r.user1 != address(0) && r.user2 != address(0), "No players");

        address winner;
        address loser;
        bool isDraw;
        bool bothLose;

        bool revealWindowExpired = block.number > r.p2JoinedBlock + revealWindow;

        if (r.revealed1 && r.revealed2) {
            (winner, loser, isDraw) = _calcOutcome(r);
        } else if (revealWindowExpired) {
            if (r.revealed1 && !r.revealed2) {
                winner = r.user1; loser = r.user2;
            } else if (!r.revealed1 && r.revealed2) {
                winner = r.user2; loser = r.user1;
            } else {
                bothLose = true;
            }
        } else {
            revert RevealStillActive();
        }

        if (!isDraw && winner != address(0) && loser != address(0)) {
            mana.consumeMana(loser, 1);

            if (r.roomType == RoomType.Public) {
                points.mint(winner, basePoints * _ticketMultiplier(winner));
            }
        } else if (bothLose) {
            mana.consumeMana(r.user1, 1);
            mana.consumeMana(r.user2, 1);
        }

        bool rewardFailed = false;
        if (r.roomType == RoomType.Public && winner != address(0)) {
            rewardFailed = _callReward(winner, loser, isDraw, roomId);
        }

        r.state = State.Finished;
        emit Resolved(roomId, winner, loser, isDraw, bothLose, r.token1, r.token2, rewardFailed);

        _closeRoom(r, roomId);
    }

    /* ─────────────  reward call (gas capped)  ───────────── */

    function _callReward(address winner, address loser, bool isDraw, uint256 roomId) internal returns (bool failed) {
        if (address(reward) == address(0)) return false;

        // gas-capped low-level call: prevents reward from consuming unlimited gas and DoS'ing
        (bool ok, ) = address(reward).call{gas: rewardGasLimit}(
            abi.encodeWithSelector(IReward.handleMatchResult.selector, winner, loser, isDraw, roomId)
        );
        return !ok;
    }

    /* ─────────────  Internal helpers  ───────────── */

    function _createRoom(address user1, bytes32 commitment, RoomType _type) internal returns (uint256 roomId) {
        roomId = nextRoomId++;
        Room storage r = rooms[roomId];

        r.user1        = user1;
        r.hash1        = commitment;
        r.createdBlock = uint40(block.number);
        r.roomType     = _type;
        r.state        = State.WaitingForP2;

        emit RoomCreated(roomId, user1, _type);
    }

    function _closeRoom(Room storage r, uint256 roomId) internal {
        if (_activeRoomOf[r.user1] == roomId) _activeRoomOf[r.user1] = 0;
        if (_activeRoomOf[r.user2] == roomId) _activeRoomOf[r.user2] = 0;
    }

    /* ---------- Element/level helpers ---------- */

    function _levelOf(uint256 tokenId) internal pure returns (uint8) {
        // tokenId already validated in reveal, but keep safety
        if (tokenId < 1 || tokenId > 25) revert InvalidTokenId();
        return uint8(((tokenId - 1) / 5) + 1);
    }

    function _elementOf(uint256 tokenId) internal pure returns (uint8) {
        return uint8(((tokenId - 1) % 5)); // 0-4
    }

    function _calcOutcome(Room storage r) internal view returns (address, address, bool) {
        uint8 lvl1 = _levelOf(r.token1);
        uint8 lvl2 = _levelOf(r.token2);

        if (lvl1 == lvl2) {
            int8 elemResult = _elementCompare(_elementOf(r.token1), _elementOf(r.token2));
            if (elemResult == 0) return (address(0), address(0), true);
            return elemResult > 0 ? (r.user1, r.user2, false) : (r.user2, r.user1, false);
        }

        if (absDiff(lvl1, lvl2) > 1) {
            return (lvl1 > lvl2) ? (r.user1, r.user2, false) : (r.user2, r.user1, false);
        } else {
            if (lvl1 > lvl2) {
                int8 elemResult = _elementCompare(_elementOf(r.token1), _elementOf(r.token2));
                if (elemResult >= 0) return (r.user1, r.user2, false);
                return (address(0), address(0), true);
            } else {
                int8 elemResult = _elementCompare(_elementOf(r.token2), _elementOf(r.token1));
                if (elemResult >= 0) return (r.user2, r.user1, false);
                return (address(0), address(0), true);
            }
        }
    }

    function _elementCompare(uint8 e1, uint8 e2) internal pure returns (int8) {
        if (e1 == e2) return 0;

        if (e1 == 0 && (e2 == 3 || e2 == 2)) return  1; // Earth > Water,Fire
        if (e1 == 1 && (e2 == 0 || e2 == 4)) return  1; // Wind  > Earth,Wood
        if (e1 == 2 && (e2 == 1 || e2 == 4)) return  1; // Fire  > Wind,Wood
        if (e1 == 3 && (e2 == 1 || e2 == 2)) return  1; // Water > Wind,Fire
        if (e1 == 4 && (e2 == 0 || e2 == 3)) return  1; // Wood  > Earth,Water
        return -_elementCompare(e2, e1);
    }

    function absDiff(uint8 a, uint8 b) private pure returns (uint8) {
        return a > b ? a - b : b - a;
    }

    /* ---------- Solo resolver (still pseudo-random) ---------- */

    function _soloOutcome(address user1) internal view returns (address, address, bool) {
        uint256 rnd = uint256(keccak256(abi.encodePacked(block.prevrandao, block.timestamp, user1))) % 3;
        if (rnd == 0) return (user1, address(0), false);
        if (rnd == 1) return (address(0), user1, false);
        return (address(0), address(0), true);
    }

    /* ---------- Ticket multiplier ---------- */

    function _ticketMultiplier(address player) internal view returns (uint256) {
        if (firstPassTokenId != 0 && ticket.balanceOf(player, firstPassTokenId) > 0) return firstPassMultiplier;
        if (businessPassTokenId != 0 && ticket.balanceOf(player, businessPassTokenId) > 0) return businessPassMultiplier;
        if (ecoPassTokenId != 0 && ticket.balanceOf(player, ecoPassTokenId) > 0) return ecoPassMultiplier;
        return 1;
    }
}