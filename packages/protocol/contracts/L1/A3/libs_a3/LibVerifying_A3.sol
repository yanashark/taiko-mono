// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.20;

import {AddressResolver} from "../../../common/AddressResolver.sol";
import {ISignalService} from "../../../signal/ISignalService.sol";
import {LibTokenomics_A3} from "./LibTokenomics_A3.sol";
import {LibUtils_A3} from "./LibUtils_A3.sol";
import {SafeCastUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/math/SafeCastUpgradeable.sol";
import {TaikoData_A3} from "../TaikoData_A3.sol";

library LibVerifying_A3 {
    using SafeCastUpgradeable for uint256;
    using LibUtils_A3 for TaikoData_A3.State;

    event BlockVerified(uint256 indexed id, bytes32 blockHash, uint64 reward);

    event CrossChainSynced(uint256 indexed srcHeight, bytes32 blockHash, bytes32 signalRoot);

    error L1_INVALID_CONFIG();

    function init(
        TaikoData_A3.State storage state,
        TaikoData_A3.Config memory config,
        bytes32 genesisBlockHash,
        uint64 initBlockFee,
        uint64 initProofTimeTarget,
        uint64 initProofTimeIssued,
        uint16 adjustmentQuotient
    ) internal {
        if (
            config.chainId <= 1 || config.maxNumProposedBlocks == 1
                || config.ringBufferSize <= config.maxNumProposedBlocks + 1
                || config.blockMaxGasLimit == 0 || config.maxTransactionsPerBlock == 0
                || config.maxBytesPerTxList == 0
            // EIP-4844 blob size up to 128K
            || config.maxBytesPerTxList > 128 * 1024 || config.maxEthDepositsPerBlock == 0
                || config.maxEthDepositsPerBlock < config.minEthDepositsPerBlock
            // EIP-4844 blob deleted after 30 days
            || config.txListCacheExpiry > 30 * 24 hours || config.ethDepositGas == 0
                || config.ethDepositMaxFee == 0 || config.ethDepositMaxFee >= type(uint96).max
                || adjustmentQuotient == 0 || initProofTimeTarget == 0 || initProofTimeIssued == 0
        ) revert L1_INVALID_CONFIG();

        uint64 timeNow = uint64(block.timestamp);
        state.genesisHeight = uint64(block.number);
        state.genesisTimestamp = timeNow;

        state.blockFee = initBlockFee;
        state.proofTimeIssued = initProofTimeIssued;
        state.proofTimeTarget = initProofTimeTarget;
        state.adjustmentQuotient = adjustmentQuotient;
        state.numBlocks = 1;

        TaikoData_A3.Block storage blk = state.blocks[0];
        blk.proposedAt = timeNow;
        blk.nextForkChoiceId = 2;
        blk.verifiedForkChoiceId = 1;

        TaikoData_A3.ForkChoice storage fc = state.blocks[0].forkChoices[1];
        fc.blockHash = genesisBlockHash;
        fc.provenAt = timeNow;

        emit BlockVerified(0, genesisBlockHash, 0);
    }

    function verifyBlocks(
        TaikoData_A3.State storage state,
        TaikoData_A3.Config memory config,
        AddressResolver resolver,
        uint256 maxBlocks
    ) internal {
        uint256 i = state.lastVerifiedBlockId;
        TaikoData_A3.Block storage blk = state.blocks[i % config.ringBufferSize];

        uint256 fcId = blk.verifiedForkChoiceId;
        assert(fcId > 0);
        bytes32 blockHash = blk.forkChoices[fcId].blockHash;
        uint32 gasUsed = blk.forkChoices[fcId].gasUsed;
        bytes32 signalRoot;

        uint64 processed;
        unchecked {
            ++i;
        }

        address systemProver = resolver.resolve("system_prover", true);
        while (i < state.numBlocks && processed < maxBlocks) {
            blk = state.blocks[i % config.ringBufferSize];
            assert(blk.blockId == i);

            fcId = LibUtils_A3.getForkChoiceId(state, blk, blockHash, gasUsed);

            if (fcId == 0) break;

            TaikoData_A3.ForkChoice storage fc = blk.forkChoices[fcId];

            if (fc.prover == address(0)) break;

            uint256 proofCooldownPeriod = fc.prover == address(1)
                ? config.systemProofCooldownPeriod
                : config.proofCooldownPeriod;

            if (block.timestamp < fc.provenAt + proofCooldownPeriod) break;

            blockHash = fc.blockHash;
            gasUsed = fc.gasUsed;
            signalRoot = fc.signalRoot;

            _markBlockVerified({
                state: state,
                blk: blk,
                fcId: uint24(fcId),
                fc: fc,
                systemProver: systemProver
            });

            unchecked {
                ++i;
                ++processed;
            }
        }

        if (processed > 0) {
            if (config.relaySignalRoot) {
                // Send the L2's signal root to the signal service so other TaikoL1
                // deployments, if they share the same signal service, can relay the
                // signal to their corresponding TaikoL2 contract.
                ISignalService(resolver.resolve("signal_service", false)).sendSignal(signalRoot);
            }
            emit CrossChainSynced(state.lastVerifiedBlockId, blockHash, signalRoot);
        }
    }

    function _markBlockVerified(
        TaikoData_A3.State storage state,
        TaikoData_A3.Block storage blk,
        TaikoData_A3.ForkChoice storage fc,
        uint24 fcId,
        address systemProver
    ) private {
        uint64 proofTime;
        unchecked {
            proofTime = uint64(fc.provenAt - blk.proposedAt);
        }

        uint64 reward = LibTokenomics_A3.getProofReward(state, proofTime);

        (state.proofTimeIssued, state.blockFee) =
            LibTokenomics_A3.getNewBlockFeeAndProofTimeIssued(state, proofTime);

        unchecked {
            state.accBlockFees -= reward;
            state.accProposedAt -= blk.proposedAt;
            ++state.lastVerifiedBlockId;
        }

        // reward the prover
        if (reward != 0) {
            address prover = fc.prover != address(1) ? fc.prover : systemProver;

            // systemProver may become address(0) after a block is proven
            if (prover != address(0)) {
                if (state.taikoTokenBalances[prover] == 0) {
                    // Reduce refund to 1 wei as a penalty if the proposer
                    // has 0 TKO outstanding balance.
                    state.taikoTokenBalances[prover] = 1;
                } else {
                    state.taikoTokenBalances[prover] += reward;
                }
            }
        }

        blk.nextForkChoiceId = 1;
        blk.verifiedForkChoiceId = fcId;

        emit BlockVerified(blk.blockId, fc.blockHash, reward);
    }
}