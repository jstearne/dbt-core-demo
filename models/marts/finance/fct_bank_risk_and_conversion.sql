-- Combines the retail-banking marketing dataset (predict_term_deposit, landed via both the
-- SQL Server and Oracle connectors) with the consumer loan-application dataset (Oracle LOAN)
-- into one bank risk / conversion view: who holds balance, who's carrying loan risk, and who
-- converted on a term-deposit campaign.
-- NOTE: predict_term_deposit columns are confirmed from the synced SQL Server schema. LOAN
-- columns are the standard Kaggle loan-prediction field set commonly used in this dataset —
-- verify against the actual synced columns and rename below if they differ.

with term_deposit_mssql as (

    select
        id,
        age,
        job,
        marital,
        education,
        "default"       as in_default,
        balance,
        housing         as has_housing_loan,
        loan            as has_personal_loan,
        contact,
        duration,
        campaign,
        pdays,
        previous,
        poutcome,
        y               as subscribed_term_deposit,
        'mssql'         as landed_via

    from {{ source('prgx_mssql_finserv_td', 'predict_term_deposit') }}

),

term_deposit_oracle as (

    select
        id,
        age,
        job,
        marital,
        education,
        "default"       as in_default,
        balance,
        housing         as has_housing_loan,
        loan            as has_personal_loan,
        contact,
        duration,
        campaign,
        pdays,
        previous,
        poutcome,
        y               as subscribed_term_deposit,
        'oracle'        as landed_via

    from {{ source('prgx_oracle_financial_services', 'predict_term_deposit') }}

),

term_deposit_deduped as (

    -- Same underlying dataset lands from two connectors; prefer the Oracle copy, fall back to
    -- SQL Server, so downstream consumers see one row per customer instead of double-counted risk.
    select *
    from (
        select *, row_number() over (partition by id order by (landed_via = 'oracle') desc) as rn
        from (
            select * from term_deposit_mssql
            union all
            select * from term_deposit_oracle
        )
    )
    where rn = 1

),

loan_applications as (

    select
        loan_id,
        gender,
        married,
        dependents,
        education,
        self_employed,
        applicantincome,
        coapplicantincome,
        loanamount,
        loan_amount_term,
        credit_history,
        property_area,
        loan_status

    from {{ source('prgx_oracle_financial_services', 'loan') }}

)

select
    td.id                                as customer_id,
    td.age,
    td.job,
    td.balance,
    td.in_default,
    td.has_housing_loan,
    td.has_personal_loan,
    td.subscribed_term_deposit,
    td.poutcome                         as prior_campaign_outcome,
    la.loan_id,
    la.loanamount                       as active_loan_amount,
    la.credit_history,
    la.loan_status,
    case
        when td.in_default = 'yes' then 'HIGH'
        when la.loan_status = 'N' and la.credit_history = 0 then 'HIGH'
        when td.has_personal_loan = 'yes' and td.balance < 0 then 'MEDIUM'
        else 'LOW'
    end                                   as risk_tier

from term_deposit_deduped td
left join loan_applications la
    on td.id = la.loan_id
