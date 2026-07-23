# prgx_dbt_models

dbt Core project transforming PRGX source data (landed via Fivetran) into finance-facing marts in Snowflake.

## Sources

Defined in `models/marts/finance/_prgx_sources.yml`:

| Source | Connector | Tables |
|---|---|---|
| `prgx_salesforce` | Salesforce | opportunity, order, bill_com_invoice_c |
| `prgx_netsuite` | NetSuite | account, contact, customer, purchaseorder, salesorder |
| `prgx_oracle_financial_services` | Oracle | loan, predict_term_deposit |
| `prgx_oracle_retail` | Oracle | avocado_prices, superstore_sales, walmart |
| `prgx_mssql_sales` | SQL Server | region, ad_events, sales_data_sample, sales_data_sample_copy |
| `prgx_mssql_finserv_td` | SQL Server | predict_term_deposit |

Each source's `database` is templated as `{{ target.database }}` — adjust per-source if PRGX data lands in dedicated databases rather than your default target database.

## Models

All models live under `models/marts/finance/` and materialize as tables:

- **fct_revenue_pipeline** — unifies open/closed revenue across Salesforce (CRM bookings) and NetSuite (ERP sales orders) into one cross-system pipeline + booked-revenue view.
- **fct_recoverable_funds** — recovery-audit style view surfacing money that could plausibly be recaptured (duplicate-payment detection, aged AR, margin-leakage review) across connected sources. This is a detection/flagging layer, not a source of truth — every row should be manually reviewed before action.
- **fct_bank_risk_and_conversion** — combines the retail-banking marketing dataset (`predict_term_deposit`, landed via both SQL Server and Oracle connectors) with the consumer loan-application dataset (Oracle `loan`) into one bank risk / conversion view.

> Field names referenced in these models are the standard defaults for each connector/dataset. Verify against actual synced schemas (`describe table`) after the first Fivetran sync and adjust any renamed or custom fields.

## Setup

1. Install dbt Core and the Snowflake adapter:
   ```
   pip install dbt-core dbt-snowflake
   ```
2. Copy `profiles.yml.example` to `~/.dbt/profiles.yml` (or your `DBT_PROFILES_DIR`) and fill in your Snowflake credentials:
   ```
   cp profiles.yml.example ~/.dbt/profiles.yml
   ```
3. Confirm the connection:
   ```
   dbt debug
   ```
4. Run the project:
   ```
   dbt run
   ```

## Project structure

```
models/
  marts/
    finance/
      _prgx_sources.yml
      fct_revenue_pipeline.sql
      fct_recoverable_funds.sql
      fct_bank_risk_and_conversion.sql
```
