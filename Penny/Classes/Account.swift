//
//  Account.swift
//  Penny
//
//  Created by Ethan Christo on 12/25/25.
//

import Foundation
import SwiftData

@Model
class Account {
    var name: String = ""
    var accountType: AccountType = AccountType.checking
    var closingDate: Int? = 1
    var dueDate: Int? = 1

    /// For checking/savings accounts, use the bank's *available* balance (posted
    /// minus pending holds) for the net total instead of the posted balance.
    /// Ignored for credit cards, which always use the posted balance.
    var useAvailableBalance: Bool = false

    /// Stable identifier from an external source (e.g. a SimpleFIN account id).
    /// Lets re-syncs match the same account instead of creating duplicates.
    var externalID: String?

    @Relationship(deleteRule: .nullify, inverse: \Transaction.account)
    var transactions: [Transaction]?

    var rules: [CategoryRules]?

    init(name: String = "", accountType: AccountType = .checking, closingDate: Int? = 1, dueDate: Int? = 1, externalID: String? = nil, useAvailableBalance: Bool = false) {
        self.name = name
        self.accountType = accountType
        self.closingDate = closingDate
        self.dueDate = dueDate
        self.externalID = externalID
        self.useAvailableBalance = useAvailableBalance
    }
}
