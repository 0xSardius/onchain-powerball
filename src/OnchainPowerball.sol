// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract OnchainPowerball is Pausable, Ownable, ReentrancyGuard {
    // Constants for game mechanics
    uint256 public constant ENTRY_FEE = 0.001 ether;
    uint256 public constant DRAWING_INTERVAL = 1 days;
    uint256 public constant MATCH_LENGTH = 6;
    
    // Constants for limits and thresholds
    uint256 public constant MAX_WINNERS_PER_TIER = 100;
    uint256 public constant MIN_PRIZE_PER_WINNER = 0.0001 ether;
    uint256 public constant MAX_ENTRIES_PER_DRAWING = 10000;
    uint256 public constant MAX_JACKPOT = 1000 ether;
    uint256 public constant MIN_RESERVE_RATIO = 10; // 10%
    uint256 public constant ENTRY_CUTOFF_TIME = 5 minutes;
    uint256 public constant PRIZE_CLAIM_DEADLINE = 30 days;
    
    struct PrizeTier {
        uint8 requiredMatches;
        uint8 percentage;
        uint256 fixedPrize;
    }
    
    PrizeTier[] public PRIZE_TIERS = [
        PrizeTier(6, 75, 0),           // All 6 digits - 75% of pot
        PrizeTier(5, 15, 0),           // 5 digits - 15% of pot
        PrizeTier(4, 5, 0),            // 4 digits - 5% of pot
        PrizeTier(3, 0, 0.0001 ether), // 3 digits - Fixed prize
        PrizeTier(2, 0, 0.00005 ether) // 2 digits - Fixed prize
    ];
    
    struct Entry {
        bytes32 txHash;
        uint256 timestamp;
        string lastDigits;
    }
    
    struct Drawing {
        bytes32 winningHash;
        string winningDigits;
        bool completed;
        mapping(uint8 => address[]) winners;
        uint256 drawingPot;
        uint256 entryCount;
        mapping(address => bool) prizesClaimed;
    }
    
    // State variables
    mapping(address => Entry[]) public entries;
    mapping(uint256 => Drawing) public drawings;
    mapping(uint256 => address[]) public dailyPlayers;
    mapping(uint256 => uint256) public drawingEntryCount;
    
    uint256 public jackpot;
    uint256 public nextDrawingTime;
    uint256 public reserveFund;
    
    // Events
    event EntrySubmitted(
        address indexed player,
        bytes32 txHash,
        string lastDigits,
        uint256 drawingTime
    );
    event DrawingComplete(
        uint256 indexed drawTime,
        bytes32 winningHash,
        string winningDigits,
        uint256 totalPrize
    );
    event PrizeAwarded(
        address indexed winner,
        uint256 amount,
        uint8 matchCount,
        bool isJackpotTier
    );
    event JackpotRollover(uint256 amount);
    event ReserveFundTopUp(uint256 amount);
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    
    constructor() {
        nextDrawingTime = (block.timestamp / 1 days + 1) * 1 days;
    }
    
    // Entry submission
    function submitEntry() external payable whenNotPaused nonReentrant {
        require(msg.value == ENTRY_FEE, "Incorrect entry fee");
        require(
            block.timestamp <= nextDrawingTime - ENTRY_CUTOFF_TIME,
            "Too close to drawing time"
        );
        require(canSubmitEntry(msg.sender), "Already entered today");
        
        uint256 currentDrawingDay = (block.timestamp / 1 days) * 1 days;
        
        // Check entry limits
        require(
            drawingEntryCount[currentDrawingDay] < MAX_ENTRIES_PER_DRAWING,
            "Maximum entries reached for this drawing"
        );
        
        // Generate entry hash with multiple entropy sources
        bytes32 txHash = keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender,
            entries[msg.sender].length,
            blockhash(block.number - 1),
            address(this)
        ));
        
        string memory lastDigits = getLastNHexDigits(txHash, MATCH_LENGTH);
        
        // Store entry
        entries[msg.sender].push(Entry({
            txHash: txHash,
            timestamp: block.timestamp,
            lastDigits: lastDigits
        }));
        
        // Update entry counts and tracking
        drawingEntryCount[currentDrawingDay]++;
        if (dailyPlayers[currentDrawingDay].length == 0 || 
            dailyPlayers[currentDrawingDay][dailyPlayers[currentDrawingDay].length - 1] != msg.sender) {
            dailyPlayers[currentDrawingDay].push(msg.sender);
        }
        
        // Split entry fee
        uint256 toJackpot = (msg.value * 90) / 100;
        uint256 toReserve = msg.value - toJackpot;
        
        _updateJackpot(toJackpot);
        reserveFund += toReserve;
        
        emit EntrySubmitted(msg.sender, txHash, lastDigits, currentDrawingDay);
    }
    
    // Drawing execution
    function conductDrawing() external whenNotPaused nonReentrant {
        require(block.timestamp >= nextDrawingTime, "Drawing time not reached");
        require(block.timestamp <= nextDrawingTime + 1 hours, "Drawing window expired");
        require(!drawings[nextDrawingTime].completed, "Drawing already completed");
        
        uint256 previousDay = nextDrawingTime - DRAWING_INTERVAL;
        require(drawingEntryCount[previousDay] > 0, "No entries for this drawing");
        
        _ensureReserveFund();
        
        bytes32 winningHash = blockhash(block.number - 1);
        string memory winningDigits = getLastNHexDigits(winningHash, MATCH_LENGTH);
        
        Drawing storage drawing = drawings[nextDrawingTime];
        drawing.winningHash = winningHash;
        drawing.winningDigits = winningDigits;
        drawing.drawingPot = jackpot;
        drawing.entryCount = drawingEntryCount[previousDay];
        
        bool hasJackpotWinner = processEntries(previousDay, drawing);
        if (!hasJackpotWinner) {
            emit JackpotRollover(jackpot);
        }
        
        drawing.completed = true;
        nextDrawingTime += DRAWING_INTERVAL;
        
        emit DrawingComplete(
            block.timestamp,
            winningHash,
            winningDigits,
            drawing.drawingPot
        );
    }
    
    // Process entries in batches
    function processEntries(uint256 drawingDay, Drawing storage drawing) 
        internal returns (bool hasJackpotWinner) 
    {
        address[] memory players = dailyPlayers[drawingDay];
        uint256 batchSize = 100;
        
        for (uint256 i = 0; i < players.length; i += batchSize) {
            uint256 endIndex = Math.min(i + batchSize, players.length);
            bool batchHasWinner = processPlayerBatch(
                players,
                i,
                endIndex,
                drawing
            );
            if (batchHasWinner) hasJackpotWinner = true;
        }
        
        return hasJackpotWinner;
    }
    
    // Process a batch of players
    function processPlayerBatch(
        address[] memory players,
        uint256 start,
        uint256 end,
        Drawing storage drawing
    ) internal returns (bool hasJackpotWinner) {
        for (uint256 i = start; i < end; i++) {
            address player = players[i];
            Entry[] memory playerEntries = entries[player];
            
            for (uint256 j = 0; j < playerEntries.length; j++) {
                Entry memory entry = playerEntries[j];
                uint8 matches = countMatches(
                    entry.lastDigits,
                    drawing.winningDigits
                );
                
                // Find applicable prize tier
                for (uint8 t = 0; t < PRIZE_TIERS.length; t++) {
                    if (matches == PRIZE_TIERS[t].requiredMatches) {
                        require(
                            drawing.winners[matches].length < MAX_WINNERS_PER_TIER,
                            "Too many winners for tier"
                        );
                        drawing.winners[matches].push(player);
                        if (matches == MATCH_LENGTH) {
                            hasJackpotWinner = true;
                        }
                        break;
                    }
                }
            }
        }
    }
    
    // Distribute prizes
    function distributePrizes(Drawing storage drawing) internal {
        for (uint8 t = 0; t < PRIZE_TIERS.length; t++) {
            PrizeTier memory tier = PRIZE_TIERS[t];
            address[] storage tierWinners = drawing.winners[tier.requiredMatches];
            
            if (tierWinners.length == 0) continue;
            
            if (tier.percentage > 0) {
                uint256 tierPrize = (drawing.drawingPot * tier.percentage) / 100;
                uint256 prizePerWinner = tierPrize / tierWinners.length;
                
                require(
                    prizePerWinner >= MIN_PRIZE_PER_WINNER,
                    "Prize per winner too small"
                );
                
                uint256 totalAwarded = 0;
                
                for (uint256 i = 0; i < tierWinners.length; i++) {
                    uint256 prize;
                    if (i == tierWinners.length - 1) {
                        prize = tierPrize - totalAwarded;
                    } else {
                        prize = prizePerWinner;
                    }
                    
                    payable(tierWinners[i]).transfer(prize);
                    totalAwarded += prize;
                    jackpot -= prize;
                    
                    emit PrizeAwarded(
                        tierWinners[i],
                        prize,
                        tier.requiredMatches,
                        true
                    );
                }
            } else if (tier.fixedPrize > 0) {
                uint256 totalPrizeNeeded = tier.fixedPrize * tierWinners.length;
                require(
                    reserveFund >= totalPrizeNeeded,
                    "Insufficient reserve for fixed prizes"
                );
                
                for (uint256 i = 0; i < tierWinners.length; i++) {
                    payable(tierWinners[i]).transfer(tier.fixedPrize);
                    reserveFund -= tier.fixedPrize;
                    
                    emit PrizeAwarded(
                        tierWinners[i],
                        tier.fixedPrize,
                        tier.requiredMatches,
                        false
                    );
                }
            }
        }
    }
    
    // Helper functions
    function _updateJackpot(uint256 amount) internal {
        require(jackpot + amount <= MAX_JACKPOT, "Jackpot would exceed maximum");
        jackpot += amount;
    }
    
    function _ensureReserveFund() internal view {
        uint256 minReserve = (jackpot * MIN_RESERVE_RATIO) / 100;
        require(reserveFund >= minReserve, "Insufficient reserve fund");
    }
    
    function getLastNHexDigits(bytes32 data, uint256 n) 
        internal pure returns (string memory) 
    {
        bytes memory hexDigits = new bytes(n * 2);
        bytes32 mask = bytes32((1 << (4 * n * 2)) - 1);
        uint256 lastNDigits = uint256(data) & uint256(mask);
        
        for(uint256 i = 0; i < n * 2; i++) {
            uint8 digit = uint8(lastNDigits & 0xf);
            hexDigits[n * 2 - 1 - i] = digit < 10 
                ? bytes1(uint8(48 + digit))
                : bytes1(uint8(87 + digit));
            lastNDigits >>= 4;
        }
        
        return string(hexDigits);
    }
    
    function countMatches(string memory entryDigits, string memory winningDigits) 
        internal pure returns (uint8) 
    {
        bytes memory entry = bytes(entryDigits);
        bytes memory winning = bytes(winningDigits);
        require(entry.length == winning.length, "Length mismatch");
        
        uint8 matches = 0;
        for (uint256 i = 0; i < entry.length; i++) {
            if (entry[i] == winning[i]) matches++;
        }
        
        return matches;
    }
    
    function canSubmitEntry(address player) public view returns (bool) {
        if (entries[player].length == 0) return true;
        
        Entry[] memory playerEntries = entries[player];
        Entry memory lastEntry = playerEntries[playerEntries.length - 1];
        
        uint256 currentPeriodStart = nextDrawingTime - DRAWING_INTERVAL;
        return lastEntry.timestamp < currentPeriodStart;
    }
    
    // Admin functions
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function topUpReserve() external payable onlyOwner {
        reserveFund += msg.value;
        emit ReserveFundTopUp(msg.value);
    }
    
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(amount <= reserveFund, "Cannot withdraw prize pool");
        reserveFund -= amount;
        payable(owner()).transfer(amount);
        emit EmergencyWithdraw(owner(), amount);
    }
    
    // View functions
    function getCurrentJackpot() external view returns (uint256) {
        return jackpot;
    }
    
    function getNextDrawingTime() external view returns (uint256) {
        return nextDrawingTime;
    }
    
    function getPlayerEntries(address player) external view returns (Entry[] memory) {
        return entries[player];
    }
    
    function getDrawingWinners(uint256 drawingTime, uint8 matches) 
        external view returns (address[] memory) 
    }

    function getDailyPlayers(uint256 day) external view returns (address[] memory) {
        return dailyPlayers[day];
    }
}
