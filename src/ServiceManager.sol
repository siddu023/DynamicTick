// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@eigenlayer/core/DelegationManager.sol";
import "@eigenlayer/core/AVSDirectory.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "v4-core/types/PoolId.sol";

contract ServiceManager {
    using ECDSA for bytes32;

    struct Task {
        PoolId poolId;
        int24 currentTick;
        bool completed;
        int24 suggestedTickLower;
        int24 suggestedTickUpper;
    }

    uint32 public latestTaskId;
    address public avsDirectory;
    DelegationManager public delegationManager;
    mapping(uint32 => Task) public tasks;

    event TaskCreated(uint32 indexed taskId, PoolId poolId, int24 currentTick);
    event TaskCompleted(uint32 indexed taskId, int24 suggestedTickLower, int24 suggestedTickUpper);

    modifier onlyValidOperator(address operator) {
        require(delegationManager.isOperator(operator), "ServiceManager: Invalid operator");
        _;
    }

    constructor(address _avsDirectory, address _delegationManager) {
        avsDirectory = _avsDirectory;
        delegationManager = DelegationManager(_delegationManager);
    }

    /// @notice Register this service in the AVS Directory.
   
    function registerService(string memory description) external {
        AVSDirectory(avsDirectory).registerService(address(this), description);
    }

    /// @notice Create a new task and emit an event for operators to process.
    /// @param poolId The PoolId to verify.
    /// @param currentTick The current tick to calculate suggested ranges.
    function createTask(PoolId poolId, int24 currentTick) internal returns (uint32) {
        uint32 taskId = latestTaskId++;
        tasks[taskId] = Task({
            poolId: poolId,
            currentTick: currentTick,
            completed: false,
            suggestedTickLower: 0,
            suggestedTickUpper: 0
        });

        emit TaskCreated(taskId, poolId, currentTick);
        return taskId;
    }

    /// @notice Submit results for a task.
    /// @param taskId The ID of the task being processed.
    /// @param suggestedTickLower Suggested lower tick for reinvestment.
    /// @param suggestedTickUpper Suggested upper tick for reinvestment.
    /// @param signature The operator's signature for verification.
    function submitTaskResult(
        uint32 taskId,
        int24 suggestedTickLower,
        int24 suggestedTickUpper,
        bytes calldata signature
    ) external onlyValidOperator(msg.sender) {
        Task storage task = tasks[taskId];
        require(!task.completed, "ServiceManager: Task already completed");

        // Verify the operator's signature
        bytes32 messageHash = keccak256(
            abi.encodePacked(task.poolId, task.currentTick, suggestedTickLower, suggestedTickUpper)
        ).toEthSignedMessageHash();
        address signer = messageHash.recover(signature);
        require(signer == msg.sender, "ServiceManager: Invalid signature");

        // Mark task as completed
        task.suggestedTickLower = suggestedTickLower;
        task.suggestedTickUpper = suggestedTickUpper;
        task.completed = true;

        emit TaskCompleted(taskId, suggestedTickLower, suggestedTickUpper);
    }

    /// @notice Main function to get suggested tick range.
    /// @param poolId The PoolId to verify.
    /// @param currentTick The current tick to calculate suggested ranges.
    /// @return suggestedTickLower Suggested lower tick for reinvestment.
    /// @return suggestedTickUpper Suggested upper tick for reinvestment.
    function getSuggestedTickRange(PoolId poolId, int24 currentTick)
        external
        returns (int24 suggestedTickLower, int24 suggestedTickUpper)
    {
        // Create a new task
        uint32 taskId = createTask(poolId, currentTick);

        // Logic for operator to process the task and submit the result
        Task storage task = tasks[taskId];
        require(task.completed, "ServiceManager: Task not yet completed");

        return (task.suggestedTickLower, task.suggestedTickUpper);
    }
}
