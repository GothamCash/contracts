// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract GothamMixer01 {
    uint256 public constant DEPOSIT_AMOUNT = 10 ether;
    uint256 public constant FEE_PERCENT = 1;
    uint256 public constant EXPIRY_TIME = 365 days;

    address public owner;

    mapping(bytes32 => bool) public commitments;
    mapping(bytes32 => bool) public nullifiers;
    mapping(bytes32 => uint256) public commitmentTimestamps;
    bytes32[] public commitmentList;

    bool public feesEnabled = false; // deposits/withdrawals are free the first month

    event Deposited(bytes32 indexed commitment, uint256 timestamp);
    event Withdrawn(address indexed to, bytes32 indexed nullifierHash);
    event ExpiredReclaimed(bytes32 indexed commitment, address indexed to);

    constructor() {
        owner = msg.sender;
    }

    /// @notice Make a deposit with a commitment hash (keccak256 note off-chain)
    function deposit(bytes32 commitment) external payable {
        uint256 requiredAmount = DEPOSIT_AMOUNT;
        if (feesEnabled) {
            // Si les frais sont activés, le déposant doit payer DEPOSIT_AMOUNT + 1%
            requiredAmount = (DEPOSIT_AMOUNT * 100) / (100 - FEE_PERCENT);
        }

        require(msg.value == requiredAmount, "Invalid amount");
        require(!commitments[commitment], "Already used");

        commitments[commitment] = true;
        commitmentTimestamps[commitment] = block.timestamp;
        commitmentList.push(commitment);

        emit Deposited(commitment, block.timestamp);
    }


    /// @notice Withdraw to a recipient by providing a nullifier and matching commitment
    function withdraw(
        bytes32 nullifierHash,
        bytes32 commitment,
        address payable recipient
    ) external {
        require(commitments[commitment], "Commitment not found");
        require(!nullifiers[nullifierHash], "Nullifier already used");

        nullifiers[nullifierHash] = true;
        commitments[commitment] = false;

        uint256 payout = DEPOSIT_AMOUNT;
        if (feesEnabled) {
            payout = (DEPOSIT_AMOUNT * (100 - FEE_PERCENT)) / 100;
        }
        recipient.transfer(payout);

        emit Withdrawn(recipient, nullifierHash);
    }

    /// @notice Reclaim expired deposits if no withdrawal was made within 1 year for that deposit
    function reclaimExpired() external {
        require(msg.sender == owner, "Not owner");

        uint256 totalReclaimed = 0;

        for (uint256 i = 0; i < commitmentList.length; i++) {
            bytes32 commitment = commitmentList[i];
            if (
                commitments[commitment] &&
                block.timestamp > commitmentTimestamps[commitment] + EXPIRY_TIME
            ) {
                commitments[commitment] = false;
                totalReclaimed += DEPOSIT_AMOUNT;
                emit ExpiredReclaimed(commitment, owner);
            }
        }

        if (totalReclaimed > 0) {
            payable(owner).transfer(totalReclaimed);
        }
    }

    /// @notice Reclaim expired deposits in batch from index `start` to `end` (excluded)
    function reclaimExpiredBatch(uint256 start, uint256 end) external {
        require(msg.sender == owner, "Not owner");
        require(start < end && end <= commitmentList.length, "Invalid range");

        uint256 totalReclaimed = 0;

        for (uint256 i = start; i < end; i++) {
            bytes32 commitment = commitmentList[i];
            if (
                commitments[commitment] &&
                block.timestamp > commitmentTimestamps[commitment] + EXPIRY_TIME
            ) {
                commitments[commitment] = false;
                totalReclaimed += DEPOSIT_AMOUNT;

                emit ExpiredReclaimed(commitment, owner);
            }
        }

        if (totalReclaimed > 0) {
            payable(owner).transfer(totalReclaimed);
        }
    }

    /// @notice Allows contract owner to change the owner address
    function changeOwner(address newOwner) external {
        require(msg.sender == owner, "Not owner");
        owner = newOwner;
    }

    /// @notice Owner can activate the fees after the initial period (and deactivate them again if necessary)
    function setFeesEnabled(bool enabled) external {
        require(msg.sender == owner, "Not owner");
        feesEnabled = enabled;
    }

    /// @notice Counts the number of commitments
    function getCommitmentCount() external view returns (uint256) {
        return commitmentList.length;
    }

    /// @notice Allows contract to receive Ether
    receive() external payable {}
}
