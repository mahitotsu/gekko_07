package com.gekko.accountservice.web;

import com.gekko.accountservice.client.AnalystAttributeClient;
import com.gekko.accountservice.client.AnalystAttributes;
import com.gekko.accountservice.domain.Account;
import com.gekko.accountservice.domain.FreezeRecord;
import com.gekko.accountservice.domain.UnfreezeExecution;
import com.gekko.accountservice.domain.UnfreezeProposal;
import com.gekko.accountservice.repo.AccountRepository;
import com.gekko.accountservice.security.AccessControl;
import com.gekko.accountservice.web.dto.AccountView;
import com.gekko.accountservice.web.dto.FreezeRequest;
import com.gekko.accountservice.web.dto.FrozenAccountView;
import com.gekko.accountservice.web.dto.ProposalView;
import com.gekko.accountservice.web.dto.ProposeRequest;
import com.gekko.accountservice.web.dto.TransactionsView;
import com.gekko.accountservice.web.dto.UnfreezeRequest;
import java.util.List;
import java.util.Optional;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

// access-control-design.md 表2のパスパターンをそのまま実装する。scope(account:read/propose/
// freeze/unfreeze)の検証はEnvoy rbac(k8s/account-service/envoy-configmap.yaml)が既に済ませて
// いるため、ここでは行わない(ADR 0009 §1・0010)。このコントローラの責務は表5のABAC判定
// (業務データ依存)のみ。
@RestController
public class AccountController {

    private final AccountRepository repository;
    private final AnalystAttributeClient analystAttributeClient;
    private final AccessControl accessControl;

    public AccountController(AccountRepository repository, AnalystAttributeClient analystAttributeClient,
            AccessControl accessControl) {
        this.repository = repository;
        this.analystAttributeClient = analystAttributeClient;
        this.accessControl = accessControl;
    }

    @GetMapping("/accounts/frozen")
    public List<FrozenAccountView> listFrozen(
            @RequestHeader("x-auth-sub") String sub,
            @RequestHeader("Authorization") String authorization) {
        Optional<AnalystAttributes> attributes = analystAttributeClient.fetch(sub, authorization);
        return repository.findFrozen().stream()
                .filter(account -> accessControl.isAllowed(attributes, account))
                .map(account -> {
                    Optional<UnfreezeProposal> proposal = repository.findLatestProposal(account.id());
                    return new FrozenAccountView(
                            account.id(),
                            account.region(),
                            account.tier(),
                            repository.findLatestFreezeRecord(account.id()).map(FreezeRecord::reason).orElse(null),
                            proposal.map(UnfreezeProposal::id).orElse(null),
                            proposal.map(UnfreezeProposal::status).orElse(null),
                            proposal.map(UnfreezeProposal::reasoning).orElse(null),
                            proposal.map(UnfreezeProposal::recommendation).orElse(null));
                })
                .toList();
    }

    @GetMapping("/accounts/{id}/transactions")
    public TransactionsView getTransactions(
            @PathVariable String id,
            @RequestHeader("x-auth-sub") String sub,
            @RequestHeader("Authorization") String authorization) {
        Account account = repository.findById(id)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));

        Optional<AnalystAttributes> attributes = analystAttributeClient.fetch(sub, authorization);
        if (!accessControl.isAllowed(attributes, account)) {
            // 表5でDENY。単一リソース照会のため、口座の存在自体を秘匿する(404)。
            throw new ResponseStatusException(HttpStatus.NOT_FOUND);
        }

        String freezeReason = repository.findLatestFreezeRecord(id).map(FreezeRecord::reason).orElse(null);
        return new TransactionsView(toView(account), freezeReason, repository.findTransactions(id));
    }

    @PostMapping("/accounts/{id}/unfreeze-proposals")
    public ProposalView propose(
            @PathVariable String id,
            @RequestHeader("x-auth-sub") String sub,
            @RequestHeader("Authorization") String authorization,
            @RequestBody(required = false) ProposeRequest request) {
        Account account = repository.findById(id)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));

        Optional<AnalystAttributes> attributes = analystAttributeClient.fetch(sub, authorization);
        if (!accessControl.isAllowed(attributes, account)) {
            // 単一リソースへの操作のため、呼び出し元は既にこの口座の存在を知っている前提。
            // 存在の秘匿ではなく権限不足を素直に伝える(403)。
            throw new ResponseStatusException(HttpStatus.FORBIDDEN);
        }

        String reasoning = (request != null && request.reasoning() != null) ? request.reasoning() : "";
        String recommendation = (request != null && request.recommendation() != null)
                ? request.recommendation() : "unfreeze";
        UnfreezeProposal proposal = repository.saveProposal(id, reasoning, sub, recommendation);
        return new ProposalView(proposal.id(), proposal.accountId(), proposal.status(), proposal.recommendation());
    }

    // 提案の承認・却下(ADR 0036)。account:unfreezeスコープ配下の人間専用操作とし、
    // fraud-agent/fraud-mcp-server(account:proposeのみ)には付与しない(k8s/account-service/
    // envoy-configmap.yaml)。承認者は提案を依頼した本人アナリストに限る(4-eyesは導入しない)。
    @PostMapping("/accounts/{id}/unfreeze-proposals/{proposalId}/approve")
    public ProposalView approveProposal(
            @PathVariable String id,
            @PathVariable String proposalId,
            @RequestHeader("x-auth-sub") String sub,
            @RequestHeader("Authorization") String authorization) {
        return decide(id, proposalId, sub, authorization, "approved");
    }

    @PostMapping("/accounts/{id}/unfreeze-proposals/{proposalId}/reject")
    public ProposalView rejectProposal(
            @PathVariable String id,
            @PathVariable String proposalId,
            @RequestHeader("x-auth-sub") String sub,
            @RequestHeader("Authorization") String authorization) {
        return decide(id, proposalId, sub, authorization, "rejected");
    }

    private ProposalView decide(String id, String proposalId, String sub, String authorization, String newStatus) {
        Account account = repository.findById(id)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));

        Optional<AnalystAttributes> attributes = analystAttributeClient.fetch(sub, authorization);
        if (!accessControl.isAllowed(attributes, account)) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN);
        }

        UnfreezeProposal proposal = repository.findProposal(proposalId)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));
        if (!proposal.accountId().equals(id)) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "proposalId does not match account");
        }
        // 承認者は提案を依頼した本人アナリスト(4-eyesは導入しない。BR9)。
        if (!proposal.proposedBySub().equals(sub)) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN, "only the requesting analyst may decide this proposal");
        }
        if (!"pending".equals(proposal.status())) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "proposal already decided");
        }

        UnfreezeProposal decided = repository.decideProposal(proposalId, newStatus, sub);
        return new ProposalView(decided.id(), decided.accountId(), decided.status(), decided.recommendation());
    }

    // fraud-detection-engineのclient_credentials呼び出し(表4・BR7)。x-auth-subは存在しない
    // (jwt_authnはsubクレームの有無を区別せず、account:freezeスコープの保有のみをゲートにする。
    // k8s/account-service/envoy-configmap.yamlのコメント参照)ため、analyst-attribute-serviceへの
    // 照会は一切行わない。
    @PostMapping("/accounts/{id}/freeze")
    public FreezeRecord freeze(@PathVariable String id, @RequestBody FreezeRequest request) {
        repository.findById(id).orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));
        repository.freeze(id, request.reason(), request.ruleFired(), request.score());
        return repository.findLatestFreezeRecord(id).orElseThrow();
    }

    @PostMapping("/accounts/{id}/unfreeze")
    public UnfreezeExecution unfreeze(
            @PathVariable String id,
            @RequestHeader("x-auth-sub") String sub,
            @RequestHeader("Authorization") String authorization,
            @RequestBody(required = false) UnfreezeRequest request) {
        Account account = repository.findById(id)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND));
        if (!account.frozen()) {
            throw new ResponseStatusException(HttpStatus.CONFLICT, "account is not frozen");
        }

        // 多層防御(backlog.md):キャッシュせず、実行の都度analyst-attribute-serviceへ再照会する。
        Optional<AnalystAttributes> attributes = analystAttributeClient.fetch(sub, authorization);
        if (!accessControl.isAllowed(attributes, account)) {
            throw new ResponseStatusException(HttpStatus.FORBIDDEN);
        }

        String proposalId = (request != null) ? request.proposalId() : null;
        if (proposalId != null) {
            UnfreezeProposal proposal = repository.findProposal(proposalId)
                    .orElseThrow(() -> new ResponseStatusException(HttpStatus.BAD_REQUEST, "unknown proposalId"));
            if (!proposal.accountId().equals(id)) {
                throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "proposalId does not match account");
            }
            // 提案経由の実行は、承認済み(ADR 0036)・承認した本人による実行であることを要求する。
            // proposalId省略時の「提案に基づかないアナリスト独自の実行」経路(BR8)はこの検証の対象外。
            if (!"approved".equals(proposal.status())) {
                throw new ResponseStatusException(HttpStatus.CONFLICT, "proposal is not approved");
            }
            if (!proposal.proposedBySub().equals(sub)) {
                throw new ResponseStatusException(HttpStatus.FORBIDDEN, "only the requesting analyst may execute this proposal");
            }
            // AIの精査結論が"keep_frozen"(根拠なし)の提案は、たとえ人間が承認(=了解)していても
            // 凍結解除の実行対象にはできない(ADR 0039。多層防御:フロントエンドのボタン出し分け
            // が壊れていても、ここで構造的に拒否する)。
            if (!"unfreeze".equals(proposal.recommendation())) {
                throw new ResponseStatusException(HttpStatus.CONFLICT, "proposal does not recommend unfreezing");
            }
        }

        return repository.unfreeze(id, proposalId, sub);
    }

    private AccountView toView(Account account) {
        return new AccountView(account.id(), account.region(), account.tier(), account.frozen());
    }
}
