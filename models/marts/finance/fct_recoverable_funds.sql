-- Recovery-audit style view: surfaces money that could plausibly be recaptured, using two
-- independent detection methods across the connected sources (duplicate-payment detection
-- and aged AR). It's a detection/flagging layer, not a source of truth; every row should be
-- manually reviewed before any action is taken on it.
--
-- A third method (retail margin-leakage, flagging line items sold at a loss) is defined below
-- but disabled — see the comment above margin_leakage for why.

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

    -- NetSuite's overduebalancesearch field is the aged/past-due portion of the customer's
    -- balance — straightforward uncollected AR, aged past a threshold worth chasing.
    select
        id                                   as entity_id,
        id                                    as source_record_id,
        overduebalancesearch                  as amount_recoverable,
        cast(null as date)                    as detected_date,
        'netsuite_customer'                   as source_system,
        'OUTSTANDING_RECEIVABLE'              as recovery_type,
        'Customer carries an open, uncollected balance' as detected_reason

    from {{ source('prgx_netsuite', 'customer') }}
    where overduebalancesearch > 0

),

-- DISABLED: the synced superstore_sales schema has no profit/discount column at all
-- (confirmed via information_schema), so margin-leakage detection can't be computed.
-- Re-enable only if a richer version of this dataset (with profit/discount) is synced.
-- Column names below are corrected to the real schema (snake_case, no spaces), but
-- amount_recoverable has no valid source column until a profit/discount field exists.
{#
margin_leakage as (

    -- Line items sold at a loss (Profit < 0) point to discounting that exceeded policy —
    -- a classic retail recovery-audit signal for margin that should have been protected.
    select
        customer_id                          as entity_id,
        row_id::varchar                      as source_record_id,
        abs(profit)                           as amount_recoverable,
        order_date                            as detected_date,
        'oracle_superstore_sales'             as source_system,
        'EXCESS_DISCOUNT_MARGIN_LOSS'         as recovery_type,
        'Line item discounted below cost (negative profit)' as detected_reason

    from {{ source('prgx_oracle_retail', 'superstore_sales') }}
    where profit < 0

),
#}

unioned as (

    select * from duplicate_invoices
    union all
    select * from aged_receivables
    -- union all
    -- select * from margin_leakage

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
