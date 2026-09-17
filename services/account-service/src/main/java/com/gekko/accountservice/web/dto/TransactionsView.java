package com.gekko.accountservice.web.dto;

import com.gekko.accountservice.domain.Transaction;
import java.util.List;

public record TransactionsView(AccountView account, String freezeReason, List<Transaction> transactions) {
}
