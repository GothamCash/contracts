/**
Gotham.cash BNB mixer - 0.1 BNB pool

Our mixer was built using simple and secured solidity functions.
Encryption is generated off-chain in a collision-resistant manner, using EDCSA and Keccak256.

To maximize the security, the contract is not deployed behind a proxy, variables are hardcoded (cannot be changed),
deposits/withdrawals cannot be paused or cancelled, the contract cannot self-destruct, and cannot be called via a delegatecall.
The contract is not deployed behind a proxy, and is thus immutable and not upgradeable.

The owner can perform only 3 actions:
a) activate/disable the fees
b) change the owner address
c) retrieve abandonned/expired (>1 year) deposits for storage efficiency, upgradeability, gas optimization and project funding.
**/

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

using ECDSA for bytes32;

library ECDSA {
    /**
     * @dev Returns an Ethereum Signed Message, created from a hash.
     * This produces hash corresponding to the one signed with the
     * eth_sign JSON-RPC method as part of EIP-191.
     */
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is the length in bytes of hash,
        // "\x19Ethereum Signed Message:\n32" is the fixed prefix
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    /**
     * @dev Returns the address that signed a hashed message (hash) with
     * signature.
     *
     * Requirements:
     *
     * - signature must be 65 bytes long.
     */
    function recover(bytes32 hash, bytes memory signature) internal pure returns (address) {
        require(signature.length == 65, "ECDSA: invalid signature length");

        bytes32 r;
        bytes32 s;
        uint8 v;

        // ecrecover takes the signature parameters, which are split from the signature bytes
        assembly {
            r := mload(add(signature, 0x20)) // first 32 bytes
            s := mload(add(signature, 0x40)) // second 32 bytes
            v := byte(0, mload(add(signature, 0x60))) // last byte
        }

        // Version of signature should be 27 or 28
        require(v == 27 || v == 28, "ECDSA: invalid signature 'v' value");

        // If the signature is valid (and not malleable), return the signer address
        address signer = ecrecover(hash, v, r, s);
        require(signer != address(0), "ECDSA: invalid signature");

        return signer;
    }
}

contract GothamMixer01 {
    using ECDSA for bytes32;
    uint256 public constant DEPOSIT_AMOUNT = 0.1 ether;
    uint256 public constant FEE_PERCENT = 1; // hard-coded, cannot change
    uint256 public constant EXPIRY_TIME = 365 days; // 1 year

    address public owner;

    mapping(bytes32 => bool) public commitments;
    mapping(bytes32 => bool) public nullifiers;
    mapping(bytes32 => uint256) public commitmentTimestamps;
    mapping(bytes32 => address) public commitmentAuthorizers; // stores the address authorizing the withdraw (signer)
    mapping(bytes32 => address) public withdrawalAuthorizations;
    bytes32[] public commitmentList;

    bool public feesEnabled = false; // deposits/withdrawals are free the first month

    event Deposited(bytes32 indexed commitment, uint256 timestamp);
    event Withdrawn(address indexed to, bytes32 indexed nullifierHash);
    event ExpiredReclaimed(bytes32 indexed commitment, address indexed to);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FeesToggled(bool enabled);

    constructor() {
        owner = msg.sender;
    }

    /// @notice Make a deposit with a commitment hash (keccak256 note off-chain)
    /// @dev The `commitment` is generated off-chain in a collision-resistant manner, using keccak256(secretNote) + salt to create entropy.
    function deposit(bytes32 commitment) external payable {
        uint256 requiredAmount = DEPOSIT_AMOUNT;
        if (feesEnabled) {
            // If fees are activated, the depositor must pay DEPOSIT_AMOUNT + 1%
            requiredAmount = (DEPOSIT_AMOUNT * 100) / (100 - FEE_PERCENT);
        }
        require(msg.value == requiredAmount, "Invalid amount");
        require(!commitments[commitment], "Already used");

        commitments[commitment] = true;
        commitmentTimestamps[commitment] = block.timestamp;
        commitmentList.push(commitment);
        commitmentAuthorizers[commitment] = msg.sender;

        if (feesEnabled) {
            uint256 feeAmount = msg.value - DEPOSIT_AMOUNT;
            payable(owner).transfer(feeAmount);
        }

        emit Deposited(commitment, block.timestamp);
    }

    // @notice Authorize the withdrawal to the signer if he provides the correct note
    function authorizeWithdrawal(
        bytes32 nullifier,
        bytes32 secret,
        address authorized,
        uint256 deadline,
        bytes calldata signature
    ) external {
        require(block.timestamp <= deadline, "Expired deadline");

        // Reconstituer le preimage et commitment
        bytes memory preimage = abi.encodePacked(nullifier, secret);
        bytes32 commitment = keccak256(preimage);

        require(commitments[commitment], "Invalid commitment");

        // Vérifier que signer connaît bien la note (preimage du commitment)
        bytes32 message = keccak256(abi.encodePacked(address(this), nullifier, secret, authorized, deadline));
        bytes32 ethSignedMessage = message.toEthSignedMessageHash();
        address signer = ethSignedMessage.recover(signature);

        // Enregistrement de l'adresse qui a autorisé le retrait
        commitmentAuthorizers[commitment] = signer;
        withdrawalAuthorizations[commitment] = authorized;
    }


    /// @notice Withdraw to a recipient by providing a nullifier and matching commitment
    function withdraw(
        bytes32 nullifier,
        bytes32 commitment,
        address payable recipient
    ) external {
        require(commitments[commitment], "Invalid commitment");
        require(!nullifiers[nullifier], "Already withdrawn");

        address authorized = withdrawalAuthorizations[commitment];
        require(authorized != address(0), "Not authorized");
        require(msg.sender == authorized, "Only authorized");

        require(recipient != address(0), "Invalid recipient");

        nullifiers[nullifier] = true;
        commitments[commitment] = false;
        withdrawalAuthorizations[commitment] = address(0);

        uint256 payout = DEPOSIT_AMOUNT;
        if (feesEnabled) {
            payout = (DEPOSIT_AMOUNT * (100 - FEE_PERCENT)) / 100;
            uint256 feeAmount = DEPOSIT_AMOUNT - payout;
            recipient.transfer(payout);
            payable(owner).transfer(feeAmount);
        } else {
            recipient.transfer(payout);
        }

        emit Withdrawn(recipient, nullifier);
    }

    /// @notice Reclaim expired deposits if no withdrawal was made within 1 year for that deposit
    /// Only work for the first 2000-3000 deposits (due to on-chain gas usage limitation), use reclaimExpiredBatch thereafter.
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
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Owner can activate the fees after the initial period (and deactivate them again if necessary)
    function setFeesEnabled(bool enabled) external {
        require(msg.sender == owner, "Not owner");
        feesEnabled = enabled;
        emit FeesToggled(enabled);
    }

    /// @notice Counts the number of commitments
    function getCommitmentCount() external view returns (uint256) {
        return commitmentList.length;
    }

    /// @notice Allows contract to receive Ether
    receive() external payable {}
}
