-- Recovery-audit style view: surfaces money that could plausibly be recaptured, using three
-- independent detection methods across the connected sources. This mirrors the classic AP/AR
-- "recovery audit" playbook (duplicate-payment detection, aged AR, and margin-leakage review) —
-- it's a detection/flagging layer, not a source of truth; every row should be manually reviewed
-- before any action is taken on it.
--
-- NOTE: Bill_com_Invoice__c field names are the typical Bill.com-managed-package defaults —
-- verify against your actual synced columns and adjust. avocado_prices / walmart were excluded
-- from the margin-leakage bucket below because neither carries a discount/profit field to key off.

with duplicate_invoices as (

    -- Same account + same amount + same calendar month = likely a duplicate AP payment.
    -- Every occurrence after the first for a given (account, amount, month) is the recoverable one.
    select
        account_lookup_c                    as entity_id,
        id                                   as source_record_id,
        invoice_amount_del_c                as amount_recoverable,
        invoice_date_c                       as detected_date,
        'salesforce_bill_com'                as source_system,
        'DUPLICATE_INVOICE_PAYMENT'          as recovery_type,
        'Same account/amount billed more than once in the same month' as detected_reason

    from (
        select
            *,
            row_number() over (
                partition by account_lookup_c, invoice_amount_del_c, date_trunc('month', invoice_date_c)
                order by invoice_date_c
            ) as occurrence_rank
        from {{ source('prgx_salesforce', 'bill_com_invoice_c') }}
    )
    where occurrence_rank > 1

),

aged_receivables as (

    -- NetSuite's standard customer.balance field is the amount currently owed by that customer —
    -- straightforward uncollected AR, aged past a threshold worth chasing.
    select
        id                                   as entity_id,
        id                                    as source_record_id,
        balance                               as amount_recoverable,
        cast(null as date)                    as detected_date,
        'netsuite_customer'                   as source_system,
        'OUTSTANDING_RECEIVABLE'              as recovery_type,
        'Customer carries an open, uncollected balance' as detected_reason

    from {{ source('prgx_netsuite', 'customer') }}
    where balance > 0

),

margin_leakage as (

    -- Line items sold at a loss (Profit < 0) point to discounting that exceeded policy —
    -- a classic retail recovery-audit signal for margin that should have been protected.
    select
        "Customer ID"                        as entity_id,
        "Row ID"::varchar                    as source_record_id,
        abs("Profit")                        as amount_recoverable,
        "Order Date"                          as detected_date,
        'oracle_superstore_sales'             as source_system,
        'EXCESS_DISCOUNT_MARGIN_LOSS'         as recovery_type,
        'Line item discounted below cost (negative profit)' as detected_reason

    from {{ source('prgx_oracle_retail', 'superstore_sales') }}
    where "Profit" < 0

),

unioned as (

    select * from duplicate_invoices
    union all
    select * from aged_receivables
    union all
    select * from margin_leakage

)

select
    entity_id,
    source_record_id,
    amount_recoverable,
    detected_date,
    source_system,
    recovery_type,
    detected_reason

from unioned
where amount_recoverable > 0
order by amount_recoverable desc
