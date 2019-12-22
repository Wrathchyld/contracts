pragma solidity ^0.5.2;

import { ERC721Full } from "openzeppelin-solidity/contracts/token/ERC721/ERC721Full.sol";
import { IERC20 } from "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import { SafeMath } from "openzeppelin-solidity/contracts/math/SafeMath.sol";


import { IStakeManager } from "./IStakeManager.sol";
import { Merkle } from "../common/lib/Merkle.sol";
import { Registry } from "../common/Registry.sol";
import { IDelegationManager } from "./IDelegationManager.sol";
import { Lockable } from "../common/mixin/Lockable.sol";
import { Staker } from "./Staker.sol";


contract DelegationManager is IDelegationManager, Lockable {
  using SafeMath for uint256;
  using Merkle for bytes32;

  IERC20 public token;
  Registry public registry;
  Staker public stakerNFT;
  uint256 public MIN_DEPOSIT_SIZE = 0;
  uint256 public totalStaked;
  uint256 public validatorHopLimit = 2; // checkpoint/epochs
  uint256 public WITHDRAWAL_DELAY = 0; // todo: remove if not needed use from stakeManager

  //@todo combine both roots

  // each validators delegation amount
  mapping (uint256 => uint256) public validatorDelegation;

  struct Delegator {
    uint256 amount;
    uint256 reward;
    uint256 claimedRewards;
    uint256 slashedAmount;
    uint256 bondedTo; // validatorId
    uint256 deactivationEpoch;// unstaking delegator
  }

  // all delegators of one validator
  mapping (uint256 => bool) public validatorUnbonding;

  // Delegator metadata
  mapping (uint256 => Delegator) public delegators;

  modifier onlyDelegator(uint256 delegatorId) {
    require(stakerNFT.ownerOf(delegatorId) == msg.sender);
    _;
  }

  modifier isDelegator(uint256 delegatorId) {
    require(stakerNFT.ownerOf(delegatorId) != address(0x0) && delegators[delegatorId].amount > 0);
    _;
  }

  constructor (address _registry, address _token, address _stakerNFT) public {
    registry = Registry(_registry);
    token = IERC20(_token);
    stakerNFT = Staker(_stakerNFT);
  }

  function unbondAll(uint256 validatorId) public /* onlyStakeManager*/ {
    validatorUnbonding[validatorId] = true;
  }

  function bondAll(uint256 validatorId) public /* onlyStakeManager*/ {
    validatorUnbonding[validatorId] = false;
  }

  function validatorUnstake(uint256 validatorId) public /* onlyStakeManager*/ {
    delete validatorDelegation[validatorId];
  }

  function stake(uint256 amount, uint256 validatorId) public onlyWhenUnlocked {
    require(stakerNFT.balanceOf(msg.sender) == 0, "No second time staking");
    require(amount >= MIN_DEPOSIT_SIZE);
    require(token.transferFrom(msg.sender, address(this), amount), "Transfer stake");
    IStakeManager stakeManager = IStakeManager(registry.getStakeManagerAddress());

    totalStaked = totalStaked.add(amount);
    uint256 currentEpoch = stakeManager.currentEpoch();
    uint256 delegatorId = stakerNFT.NFTCounter();
    delegators[delegatorId] = Delegator({
      deactivationEpoch: 0,
      amount: amount,
      claimedRewards: 0,
      slashedAmount: 0,
      reward: 0,
      bondedTo: validatorId
      });

    stakerNFT.mint(msg.sender);
    if (validatorId > 0) {
      _bond(delegatorId, validatorId, currentEpoch, stakeManager);
    }
    emit Staked(msg.sender, delegatorId, currentEpoch, amount, totalStaked);
  }

  function unstake(uint256 delegatorId) public onlyDelegator(delegatorId) {
    IStakeManager stakeManager = IStakeManager(registry.getStakeManagerAddress());
    uint256 currentEpoch = stakeManager.currentEpoch();

    if (delegators[delegatorId].bondedTo != 0) {
      _unbond(delegatorId, currentEpoch, stakeManager);
    }

    require(delegators[delegatorId].deactivationEpoch == 0);
    delegators[delegatorId].deactivationEpoch = currentEpoch.add(WITHDRAWAL_DELAY);
    emit UnstakeInit(msg.sender, delegatorId, delegators[delegatorId].deactivationEpoch);
  }

  // after unstaking wait for WITHDRAWAL_DELAY, in order to claim stake back
  function unstakeClaim(
    uint256 delegatorId,
    uint256 rewardAmount,
    uint256 slashedAmount,
    uint256 accIndex,
    bytes memory accProof
    ) public onlyDelegator(delegatorId) {
    IStakeManager stakeManager = IStakeManager(registry.getStakeManagerAddress());
    require(
      keccak256(
        abi.encodePacked(
          delegatorId,
          rewardAmount,
          slashedAmount)
          ).checkMembership(
            accIndex,
            stakeManager.accountStateRoot(),
            accProof),
      "Wrong account proof"
      );
    Delegator delegator = delegators[delegatorId];
    require(
      delegators[delegatorId].deactivationEpoch > 0 &&
      delegators[delegatorId].deactivationEpoch.add(
      stakeManager.WITHDRAWAL_DELAY()) <= stakeManager.currentEpoch(),
      "Incomplete withdraw Period"
      );

    uint256 _reward = accumBalance.sub(delegator.claimedRewards);
    uint256 slashedAmount = accumSlashedAmount.sub(delegator.slashedAmount);

    uint256 amount = delegator.amount.sub(slashedAmount);
    totalStaked = totalStaked.sub(delegator.amount);

    //@todo :add slashing, take slashedAmount into account for totalStaked
    stakerNFT.burn(delegatorId);
    // @todo merge delegationManager/stakeManager capital and rewards
    require(stakeManager.delegationTransfer(delegator.reward.add(_reward), stakerNFT.ownerOf(delegatorId)),"Amount transfer failed");
    require(token.transfer(msg.sender, amount));
    delete delegators[delegatorId];
    emit Unstaked(msg.sender, delegatorId, amount, totalStaked);
  }

  function bond(uint256 delegatorId, uint256 validatorId) public onlyDelegator(delegatorId) {
    IStakeManager stakeManager = IStakeManager(registry.getStakeManagerAddress());
    uint256 currentEpoch = stakeManager.currentEpoch(); //TODO add 1

    if (delegators[delegatorId].bondedTo != 0) {
      emit ReBonding(delegatorId, delegators[delegatorId].bondedTo, validatorId);
      _unbond(delegatorId, currentEpoch, stakeManager);
     } else {
      emit Bonding(delegatorId, validatorId, delegators[delegatorId].amount);
     }
    _bond(delegatorId, validatorId, currentEpoch, stakeManager);
  }

  function _bond(uint256 delegatorId, uint256 validatorId, uint256 epoch, IStakeManager stakeManager) private {
    require(!validatorUnbonding[validatorId], "Validator is not accepting delegation");
    require(stakeManager.isValidator(validatorId), "Unknown validatorId or validator doesn't expect delegations");

    // require(delegator.lastValidatorEpoch.add(validatorHopLimit) <= currentEpoch, "Delegation_Limit_Reached");
    Delegator storage delegator = delegators[delegatorId];
    delegator.bondedTo = validatorId;
    validatorDelegation[validatorId] = validatorDelegation[validatorId].add(delegator.amount);
    stakeManager.updateValidatorState(validatorId, epoch, int(delegator.amount));
    emit Bonding(delegatorId, validatorId, delegator.amount);
  }

  function unBond(uint256 delegatorId) public onlyDelegator(delegatorId) {
    // TODO: validator amount update
    IStakeManager stakeManager = IStakeManager(registry.getStakeManagerAddress());
    // _claimRewards(delegatorId);
    uint256 currentEpoch = stakeManager.currentEpoch();
    _unbond(delegatorId, currentEpoch, stakeManager);
    emit UnBonding(delegatorId, delegators[delegatorId].bondedTo);
  }

  function _unbond(uint256 delegatorId, uint256 epoch,  IStakeManager stakeManager) private {
    stakeManager.updateValidatorState(delegators[delegatorId].bondedTo, epoch, -int(delegators[delegatorId].amount));
    validatorDelegation[delegators[delegatorId].bondedTo] = validatorDelegation[delegators[delegatorId].bondedTo].sub(delegators[delegatorId].amount);
    delegators[delegatorId].bondedTo = 0;
  }

  function reStake(uint256 delegatorId, uint256 amount, bool stakeRewards) public onlyDelegator(delegatorId) {
    Delegator storage delegator = delegators[delegatorId];
    if (amount > 0) {
      require(token.transferFrom(msg.sender, address(this), amount), "Transfer stake");
    }
    if (stakeRewards) {
      amount += delegator.reward;
      delegator.reward = 0;
    }
    totalStaked = totalStaked.add(amount);
    if (delegator.bondedTo != 0) {
      validatorDelegation[delegators[delegatorId].bondedTo] = validatorDelegation[delegators[delegatorId].bondedTo].add(delegator.amount);
    }

    delegator.amount = delegator.amount.add(amount);
    emit ReStaked(delegatorId, amount, totalStaked);
  }

  function slash(uint256[] memory _delegators, uint256 slashRate) public  {
      // Validate
      // for (uint256 i; i < _delegators.length; i++) {
      //   Delegator storage delegator = delegators[_delegators[i]];
      //   delegator.amount = delegator.amount.sub(delegator.amount.mul(slashRate).div(100));
      // }
      // uint256 slashedAmount = 0
      // validatorDelegation[validatorId] = validatorDelegation[validatorId].sub(amount);
  }

  function claimRewards(
    uint256 delegatorId,
    uint256 accumBalance,
    uint256 accumSlashedAmount,
    uint256 accIndex,
    bool withdraw,
    bytes memory accProof
    ) public isDelegator(delegatorId) /*onlyDelegator(delegatorId) */ {
    IStakeManager stakeManager = IStakeManager(registry.getStakeManagerAddress());
    require(
      keccak256(
        abi.encodePacked(
          delegatorId,
          accumBalance,
          accumSlashedAmount)
          ).checkMembership(
            accIndex,
            stakeManager.accountStateRoot(),
            accProof),
      "Wrong account proof"
      );

    Delegator delegator = delegators[delegatorId];

    uint256 _reward = accumBalance.sub(delegator.claimedRewards);
    uint256 slashedAmount = accumSlashedAmount.sub(delegator.slashedAmount);
    uint256 _amount;

    if (_reward < slashedAmount) {
      _amount = slashedAmount.sub(_reward);
      totalStaked = totalStaked.sub(amount);
      delegator.amount = delegator.amount.sub(_amount);
      // emit StakeUpdate(delegatorId, _amount, delegator.amount);
    } else {
      delegator.reward = delegator.reward.add(_reward.sub(slashedAmount));
    }

    totalRewardsLiquidated += _reward;
    require(totalRewardsLiquidated <= totalRewards, "Liquidating more rewards then checkpoints submitted");// pos 2/3+1 is colluded
    delegator.claimedRewards = accumBalance;
    delegator.slashedAmount = accumSlashedAmount;

    if (withdraw) {
      withdrawRewards(delegatorId);
    }
  }

  function withdrawRewards(uint256 delegatorId) public {
    IStakeManager stakeManager = IStakeManager(registry.getStakeManagerAddress());
    uint256 amount = delegators[delegatorId].reward;
    require(amount > 0, "Witdraw amount must be non-zero");
    delegators[delegatorId].reward = 0;
    require(stakeManager.delegatorWithdrawal(amount, stakerNFT.ownerOf(delegatorId)),"Amount transfer failed");
  }

}
