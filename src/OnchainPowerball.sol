// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract OnchainPowerball is Pausable, Ownable, ReentrancyGuard {
    // Constants
    uint256 public constant ENTRY_FEE = 0.001 ether;
    uint256 public constant DRAWING_INTERVAL = 1 days;
    uint256 public constant MATCH_LENGTH = 6; // Increased to allow more combinations
    
    // Prize tier structure (similar to Powerball odds)
    struct PrizeTier {
        uint8 requiredMatches;  // Number of matching characters needed
        uint8 percentage;       // Percentage of jackpot for this tier
        uint256 fixedPrize;    // Fixed prize amount (in wei) if no percentage
    }
    
    // Initialize prize tiers to mirror Powerball-like probabilities
    PrizeTier[] public PRIZE_TIERS = [
        PrizeTier(6, 75, 0),          // All 6 digits match (like 5+1 in Powerball) - 75% of pot
        PrizeTier(5, 15, 0),          // 5 digits match (like 5+0) - 15% of pot
        PrizeTier(4, 5, 0),           // 4 digits match (like 4+1) - 5% of pot
        PrizeTier(3, 0, 0.0001 ether),// 3 digits match (like 4+0) - Fixed prize
        PrizeTier(2, 0, 0.00005 ether)// 2 digits match (like 3+1) - Fixed prize
    ];
    
    // State variables
    struct Entry {
        bytes32 txHash;
        uint256 timestamp;
        string lastDigits;     // Last MATCH_LENGTH digits of txHash in hex
    }
    
    struct Drawing {
        bytes32 winningHash;
        string winningDigits;
        bool completed;
        mapping(uint8 => address[]) winners; // matches => winners
        uint256 drawingPot;    // Total pot for this drawing
    }
    
    mapping(address => Entry[]) public entries;
    mapping(uint256 => Drawing) public drawings;      // drawingTime => Drawing
    mapping(uint256 => address[]) public dailyPlayers; // drawingTime => players
    
    uint256 public jackpot;
    uint256 public nextDrawingTime;
    uint256 public reserveFund;  // For fixed prize payouts
    
    // Events
    event EntrySubmitted(address indexed player, bytes32 txHash, string lastDigits);
    event DrawingComplete(uint256 indexed drawTime, bytes32 winningHash, string winningDigits);
    event PrizeAwarded(
        address indexed winner, 
        uint256 amount, 
        uint8 matchCount, 
        bool isJackpotTier
    );
    event JackpotRollover(uint256 amount);
    event EmergencyWithdraw(address indexed owner, uint256 amount);
    
    constructor() {
        // Set first drawing time to next UTC midnight
        nextDrawingTime = (block.timestamp / 1 days + 1) * 1 days;
    }
    
    // Entry submission
    function submitEntry() external payable whenNotPaused nonReentrant {
        require(msg.value == ENTRY_FEE, "Incorrect entry fee");
        require(canSubmitEntry(msg.sender), "Already entered today");
        
        // Generate entry hash using block variables and sender
        bytes32 txHash = keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender,
            entries[msg.sender].length
        ));
        
        // Convert last MATCH_LENGTH bytes to hex string
        string memory lastDigits = getLastNHexDigits(txHash, MATCH_LENGTH);
        
        // Store entry
        entries[msg.sender].push(Entry({
            txHash: txHash,
            timestamp: block.timestamp,
            lastDigits: lastDigits
        }));
        
        // Track daily players
        uint256 drawingDay = (block.timestamp / 1 days) * 1 days;
        if (dailyPlayers[drawingDay].length == 0 || 
            dailyPlayers[drawingDay][dailyPlayers[drawingDay].length - 1] != msg.sender) {
            dailyPlayers[drawingDay].push(msg.sender);
        }
        
        // Split entry fee: 90% to jackpot, 10% to reserve fund
        jackpot += (msg.value * 90) / 100;
        reserveFund += (msg.value * 10) / 100;
        
        emit EntrySubmitted(msg.sender, txHash, lastDigits);
    }
    
    // Drawing execution
    function conductDrawing() external whenNotPaused nonReentrant {
        require(block.timestamp >= nextDrawingTime, "Drawing time not reached");
        require(!drawings[nextDrawingTime].completed, "Drawing already completed");
        
        // Use block hash as source of randomness
        bytes32 winningHash = blockhash(block.number - 1);
        string memory winningDigits = getLastNHexDigits(winningHash, MATCH_LENGTH);
        
        // Initialize drawing
        Drawing storage drawing = drawings[nextDrawingTime];
        drawing.winningHash = winningHash;
        drawing.winningDigits = winningDigits;
        drawing.drawingPot = jackpot; // Store current jackpot for this drawing
        
        uint256 previousDay = nextDrawingTime - DRAWING_INTERVAL;
        address[] memory players = dailyPlayers[previousDay];
        bool hasJackpotWinner = false;

        // Process each player's entries
        for (uint256 i = 0; i < players.length; i++) {
            address player = players[i];
            Entry[] memory playerEntries = entries[player];
            
            for (uint256 j = 0; j < playerEntries.length; j++) {
                if (playerEntries[j].timestamp < previousDay) continue;
                
                // Count matching digits
                uint8 matches = countMatches(
                    playerEntries[j].lastDigits,
                    winningDigits
                );
                
                // Find applicable prize tier
                for (uint8 t = 0; t < PRIZE_TIERS.length; t++) {
                    if (matches == PRIZE_TIERS[t].requiredMatches) {
                        drawing.winners[matches].push(player);
                        if (matches == MATCH_LENGTH) {
                            hasJackpotWinner = true;
                        }
                        break;
                    }
                }
            }
        }
        
        // Distribute prizes
        for (uint8 t = 0; t < PRIZE_TIERS.length; t++) {
            PrizeTier memory tier = PRIZE_TIERS[t];
            address[] storage tierWinners = drawing.winners[tier.requiredMatches];
            
            if (tierWinners.length > 0) {
                if (tier.percentage > 0) {
                    // Percentage-based prize
                    uint256 tierPrize = (drawing.drawingPot * tier.percentage) / 100;
                    uint256 prizePerWinner = tierPrize / tierWinners.length;
                    
                    for (uint256 i = 0; i < tierWinners.length; i++) {
                        payable(tierWinners[i]).transfer(prizePerWinner);
                        emit PrizeAwarded(
                            tierWinners[i],
                            prizePerWinner,
                            tier.requiredMatches,
                            true
                        );
                    }
                    jackpot -= tierPrize;
                } else if (tier.fixedPrize > 0) {
                    // Fixed prize
                    for (uint256 i = 0; i < tierWinners.length; i++) {
                        require(
                            reserveFund >= tier.fixedPrize,
                            "Insufficient reserve for fixed prizes"
                        );
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
        
        // If no jackpot winner, roll over the jackpot
        if (!hasJackpotWinner) {
            emit JackpotRollover(jackpot);
        }
        
        drawing.completed = true;
        nextDrawingTime += DRAWING_INTERVAL;
        
        emit DrawingComplete(block.timestamp, winningHash, winningDigits);
    }
    
    // Helper functions remain the same...
    
    function getLastNHexDigits(bytes32 data, uint256 n) internal pure returns (string memory) {
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
        
        return lastEntry.timestamp < nextDrawingTime - DRAWING_INTERVAL;
    }
    
    // Emergency and admin functions
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    function emergencyWithdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        payable(owner()).transfer(balance);
        emit EmergencyWithdraw(owner(), balance);
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
    {
        return drawings[drawingTime].winners[matches];
    }
    
    function getDailyPlayers(uint256 day) external view returns (address[] memory) {
        return dailyPlayers[day];
    }
}