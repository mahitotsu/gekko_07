package com.gekko.accountservice.security;

import com.gekko.accountservice.client.AnalystAttributes;
import com.gekko.accountservice.domain.Account;
import java.util.Optional;
import org.springframework.stereotype.Component;

// access-control-design.md 表5(BR1・BR2・BR3)の実装。属性未登録・地域不一致は常にDENY。
// 地域一致の場合、standard口座はjunior/senior問わずALLOW、high-value口座はsenior限定ALLOW。
@Component
public class AccessControl {

    public boolean isAllowed(Optional<AnalystAttributes> attributes, Account account) {
        if (attributes.isEmpty()) {
            return false;
        }
        AnalystAttributes attrs = attributes.get();
        if (!attrs.regions().contains(account.region())) {
            return false;
        }
        if ("high-value".equals(account.tier())) {
            return "senior".equals(attrs.level());
        }
        return true;
    }
}
