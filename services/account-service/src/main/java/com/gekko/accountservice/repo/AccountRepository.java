package com.gekko.accountservice.repo;

import com.gekko.accountservice.domain.Account;
import com.gekko.accountservice.domain.FreezeRecord;
import com.gekko.accountservice.domain.Transaction;
import com.gekko.accountservice.domain.UnfreezeExecution;
import com.gekko.accountservice.domain.UnfreezeProposal;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

// 口座・取引・凍結記録・凍結解除提案/実行をまとめて扱う。いずれも1つの集約(口座)を中心にした
// 単純なCRUDであり、集約ごとにリポジトリを分けるほどの複雑さがないため単一クラスにしている。
@Repository
public class AccountRepository {

    private final NamedParameterJdbcTemplate jdbc;

    public AccountRepository(NamedParameterJdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    public Optional<Account> findById(String id) {
        try {
            Account account = jdbc.queryForObject(
                    "SELECT id, region, tier, frozen FROM accounts WHERE id = :id",
                    new MapSqlParameterSource("id", id),
                    (rs, rowNum) -> new Account(rs.getString("id"), rs.getString("region"), rs.getString("tier"), rs.getBoolean("frozen")));
            return Optional.ofNullable(account);
        } catch (EmptyResultDataAccessException e) {
            return Optional.empty();
        }
    }

    public List<Account> findFrozen() {
        return jdbc.query(
                "SELECT id, region, tier, frozen FROM accounts WHERE frozen = TRUE ORDER BY id",
                (rs, rowNum) -> new Account(rs.getString("id"), rs.getString("region"), rs.getString("tier"), rs.getBoolean("frozen")));
    }

    public List<Transaction> findTransactions(String accountId) {
        return jdbc.query(
                "SELECT id, account_id, amount, occurred_at, description FROM transactions "
                        + "WHERE account_id = :accountId ORDER BY occurred_at DESC",
                new MapSqlParameterSource("accountId", accountId),
                (rs, rowNum) -> new Transaction(
                        rs.getLong("id"),
                        rs.getString("account_id"),
                        rs.getBigDecimal("amount"),
                        rs.getObject("occurred_at", OffsetDateTime.class),
                        rs.getString("description")));
    }

    public Optional<FreezeRecord> findLatestFreezeRecord(String accountId) {
        try {
            FreezeRecord record = jdbc.queryForObject(
                    "SELECT id, account_id, reason, rule_fired, score, created_at FROM freeze_records "
                            + "WHERE account_id = :accountId ORDER BY created_at DESC LIMIT 1",
                    new MapSqlParameterSource("accountId", accountId),
                    (rs, rowNum) -> new FreezeRecord(
                            rs.getLong("id"),
                            rs.getString("account_id"),
                            rs.getString("reason"),
                            rs.getString("rule_fired"),
                            rs.getBigDecimal("score"),
                            rs.getObject("created_at", OffsetDateTime.class)));
            return Optional.ofNullable(record);
        } catch (EmptyResultDataAccessException e) {
            return Optional.empty();
        }
    }

    public void freeze(String accountId, String reason, String ruleFired, BigDecimal score) {
        jdbc.update("UPDATE accounts SET frozen = TRUE WHERE id = :id",
                new MapSqlParameterSource("id", accountId));
        jdbc.update(
                "INSERT INTO freeze_records (account_id, reason, rule_fired, score) "
                        + "VALUES (:accountId, :reason, :ruleFired, :score)",
                new MapSqlParameterSource()
                        .addValue("accountId", accountId)
                        .addValue("reason", reason)
                        .addValue("ruleFired", ruleFired)
                        .addValue("score", score));
    }

    public UnfreezeProposal saveProposal(String accountId, String reasoning, String proposedBySub) {
        String id = UUID.randomUUID().toString();
        jdbc.update(
                "INSERT INTO unfreeze_proposals (id, account_id, reasoning, proposed_by_sub) "
                        + "VALUES (:id, :accountId, :reasoning, :proposedBySub)",
                new MapSqlParameterSource()
                        .addValue("id", id)
                        .addValue("accountId", accountId)
                        .addValue("reasoning", reasoning)
                        .addValue("proposedBySub", proposedBySub));
        return findProposal(id).orElseThrow();
    }

    public Optional<UnfreezeProposal> findProposal(String proposalId) {
        try {
            UnfreezeProposal proposal = jdbc.queryForObject(
                    "SELECT id, account_id, reasoning, proposed_by_sub, created_at, status, decided_by_sub, decided_at "
                            + "FROM unfreeze_proposals WHERE id = :id",
                    new MapSqlParameterSource("id", proposalId),
                    (rs, rowNum) -> new UnfreezeProposal(
                            rs.getString("id"),
                            rs.getString("account_id"),
                            rs.getString("reasoning"),
                            rs.getString("proposed_by_sub"),
                            rs.getObject("created_at", OffsetDateTime.class),
                            rs.getString("status"),
                            rs.getString("decided_by_sub"),
                            rs.getObject("decided_at", OffsetDateTime.class)));
            return Optional.ofNullable(proposal);
        } catch (EmptyResultDataAccessException e) {
            return Optional.empty();
        }
    }

    public Optional<UnfreezeProposal> findLatestProposal(String accountId) {
        try {
            UnfreezeProposal proposal = jdbc.queryForObject(
                    "SELECT id, account_id, reasoning, proposed_by_sub, created_at, status, decided_by_sub, decided_at "
                            + "FROM unfreeze_proposals WHERE account_id = :accountId ORDER BY created_at DESC LIMIT 1",
                    new MapSqlParameterSource("accountId", accountId),
                    (rs, rowNum) -> new UnfreezeProposal(
                            rs.getString("id"),
                            rs.getString("account_id"),
                            rs.getString("reasoning"),
                            rs.getString("proposed_by_sub"),
                            rs.getObject("created_at", OffsetDateTime.class),
                            rs.getString("status"),
                            rs.getString("decided_by_sub"),
                            rs.getObject("decided_at", OffsetDateTime.class)));
            return Optional.ofNullable(proposal);
        } catch (EmptyResultDataAccessException e) {
            return Optional.empty();
        }
    }

    public UnfreezeProposal decideProposal(String proposalId, String status, String decidedBySub) {
        jdbc.update(
                "UPDATE unfreeze_proposals SET status = :status, decided_by_sub = :decidedBySub, decided_at = now() "
                        + "WHERE id = :id",
                new MapSqlParameterSource()
                        .addValue("id", proposalId)
                        .addValue("status", status)
                        .addValue("decidedBySub", decidedBySub));
        return findProposal(proposalId).orElseThrow();
    }

    public UnfreezeExecution unfreeze(String accountId, String proposalId, String executedBySub) {
        jdbc.update("UPDATE accounts SET frozen = FALSE WHERE id = :id",
                new MapSqlParameterSource("id", accountId));
        jdbc.update(
                "INSERT INTO unfreeze_executions (account_id, proposal_id, executed_by_sub) "
                        + "VALUES (:accountId, :proposalId, :executedBySub)",
                new MapSqlParameterSource()
                        .addValue("accountId", accountId)
                        .addValue("proposalId", proposalId)
                        .addValue("executedBySub", executedBySub));
        return jdbc.queryForObject(
                "SELECT id, account_id, proposal_id, executed_by_sub, executed_at FROM unfreeze_executions "
                        + "WHERE account_id = :accountId ORDER BY executed_at DESC LIMIT 1",
                new MapSqlParameterSource("accountId", accountId),
                (rs, rowNum) -> new UnfreezeExecution(
                        rs.getLong("id"),
                        rs.getString("account_id"),
                        rs.getString("proposal_id"),
                        rs.getString("executed_by_sub"),
                        rs.getObject("executed_at", OffsetDateTime.class)));
    }
}
