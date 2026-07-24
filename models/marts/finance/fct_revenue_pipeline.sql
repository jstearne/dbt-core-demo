-- Unifies open/closed revenue across Salesforce (CRM bookings) and NetSuite (ERP sales orders)
-- into one cross-system pipeline + booked-revenue view.
-- NOTE: Salesforce field names below are the Salesforce standard-object defaults; NetSuite
-- field names are the standard SuiteAnalytics Connect defaults. Verify against `describe table`
-- output after the first Fivetran sync and adjust any renamed/custom fields.

with sfdc_opportunities as (

    select
        id                      as source_record_id,
        account_id              as account_id,
        name                    as record_name,
        stagename               as status,
        amount                  as amount,
        closedate               as record_date,
        iswon                   as is_won,
        isclosed                as is_closed,
        'salesforce_opportunity'    as source_system,
        'pipeline'                  as record_type

    from {{ source('prgx_salesforce', 'opportunity') }}

),

sfdc_orders as (

    select
        id                      as source_record_id,
        accountid               as account_id,
        ordernumber             as record_name,
        status                  as status,
        totalamount             as amount,
        effectivedate           as record_date,
        (status = 'Activated')  as is_won,
        (status in ('Activated','Cancelled'))  as is_closed,
        'salesforce_order'          as source_system,
        'booked_order'              as record_type

    from {{ source('prgx_salesforce', 'order') }}

),

netsuite_sales_orders as (

    select
        id                      as source_record_id,
        entity                  as account_id,
        tranid                  as record_name,
        status                  as status,
        total                   as amount,
        trandate                as record_date,
        (status ilike '%Billed%' or status ilike '%Fulfilled%')  as is_won,
        (status not ilike '%Pending%')                            as is_closed,
        'netsuite_sales_order'      as source_system,
        'booked_order'              as record_type

    from {{ source('prgx_netsuite', 'salesorder') }}

),

unioned as (

    select * from sfdc_opportunities
    union all
    select * from sfdc_orders
    union all
    select * from netsuite_sales_orders

)

select
    source_record_id,
    account_id,
    record_name,
    status,
    amount,
    record_date,
    is_won,
    is_closed,
    source_system,
    record_type,
    sum(case when is_won then amount else 0 end)
        over (partition by account_id)     as account_won_revenue_to_date

from unioned
