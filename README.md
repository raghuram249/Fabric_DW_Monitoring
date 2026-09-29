# Microsoft Fabric Warehouse Monitoring

Read-only SQL diagnostics and a browser-based troubleshooting runbook for **Microsoft Fabric Warehouse**. Use this repository to investigate active requests, blocking, open transactions, locks, and historical workload patterns.

This is a collection of manually executed diagnostic queries and reference material, not a deployed monitoring service. It does not collect telemetry automatically, configure alerts, or perform remediation.

## Repository contents

| File | Purpose | Scope |
| --- | --- | --- |
| [Preflight.sql](Preflight.sql) | Record database/session context and probe required DMV columns. | Current connection; column binding only. |
| [Active-requests.sql](Active-requests.sql) | List requests by elapsed time, including waits, blockers, and application attribution. Flag requests running for at least five minutes. | Target Warehouse. |
| [Blocking-Sessions.sql](Blocking-Sessions.sql) | Show blocked requests and available blocker-session details, retaining leads to idle or inaccessible blockers. | All visible databases, with target-database requests first. |
| [Open-transactions.sql](Open-transactions.sql) | Find sessions with open transactions and identify candidates with no observed active request. | All visible sessions; not proof of transaction ownership in the target Warehouse. |
| [Lock-inventory.sql](Lock-inventory.sql) | Inventory granted, waiting, and converting locks with raw resource and status fields. | Target Warehouse. |
| [Active-connections.sql](Active-connections.sql) | Inspect connection age, sessions, and application attribution. | Optional, workspace Admin only; potentially broader than the target Warehouse. |
| [Workload-assessment.sql](Workload-assessment.sql) | Analyze historical requests, latency, query shapes, request overlap, and SQL-pool pressure events. | Query Insights views on each connected Warehouse. |
| [index.html](index.html) | General troubleshooting runbook with scenario guidance, diagrams, SQL examples, and documentation references. | Connectivity, permissions, failures, performance, capacity, ingestion, data correctness, and locking. |

## Prerequisites

- An accessible **Microsoft Fabric Warehouse** and an approved Microsoft Entra identity.
- SQL Server Management Studio (SSMS) or the Fabric SQL query editor.
- Permission to access the relevant diagnostic views. Results depend on your role and visibility.
- An approved location for exporting diagnostic results.

These scripts target Fabric Warehouse. Do not assume they are interchangeable with Azure Synapse Dedicated SQL Pool, SQL Server, or a Lakehouse SQL analytics endpoint.

### Access and visibility

The included runbook describes the following Fabric access requirements. Consult the linked Microsoft documentation for current requirements.

| Diagnostic surface | Access considerations |
| --- | --- |
| Live sessions and requests | Workspace Admin provides all-user visibility within the workspace. Member, Contributor, and Viewer see their own sessions and requests only. |
| Live connections | `sys.dm_exec_connections` requires workspace Admin; skip `Active-connections.sql` otherwise. |
| Lock inventory | Fabric blocking guidance documents Viewer as the minimum role. Lock access does not imply complete visibility into owning sessions. |
| Query Insights request history | Contributor or higher. Check availability of the required views and columns before collecting workload history. |

Use an existing authorized administrator for workload-wide collection rather than broadening permissions solely to run these queries. A successful preflight does **not** prove all-user visibility.

## Quick start

1. Clone or download the repository:

   ```powershell
   git clone https://github.com/raghuram249/Fabric_DW_Monitoring.git
   Set-Location Fabric_DW_Monitoring
   ```

2. Connect to the intended Warehouse using SSMS or the Fabric SQL query editor. Use a **separate diagnostic connection**, not the application connection being investigated.
3. Execute `Preflight.sql`. Confirm `current_database`, `current_database_id`, and `diagnostic_session_id`. Resolve missing-column or permission errors before continuing.
4. Run only the scripts relevant to the symptom. For a slow active request, start with `Active-requests.sql`. For suspected blocking, also collect `Blocking-Sessions.sql`, `Open-transactions.sql`, and `Lock-inventory.sql`.
5. Save results with their collection timestamps, connection context, and known visibility limitations. Capture another snapshot if you need to establish whether the condition persists.

The live collectors exclude the diagnostic session where their filters specify `@@SPID`. Their results are separate point-in-time observations, not an atomic snapshot.

### Reading live results

| Observation | Interpretation |
| --- | --- |
| `is_long_running = 1` | Request elapsed time is at least 300 seconds. This is a triage threshold, not proof of a fault. Change `300000` in `Active-requests.sql` if a different threshold is appropriate. |
| `is_idle_candidate = 1` | A session has open transactions but no visible active request. Confirm visibility and ownership before drawing conclusions. |
| `SPECIAL_BLOCKER_VALUE` | A negative blocker identifier requires special interpretation; it is not an ordinary session ID. |
| `SESSION_NOT_VISIBLE_OR_CHANGED` | Blocker details were not available at collection time. Do not assume there is no blocker. |
| `WAIT_OR_CONVERSION` | The lock is waiting or converting. A granted lock alone does not establish harmful blocking. |
| 201 rows, or 501 lock rows | The intended 200-row or 500-row reporting limit has been exceeded. Treat the collection as potentially incomplete. |
| No rows | No matching rows were visible at collection time; this is not proof of a healthy workload. |

Use session login times alongside session IDs when correlating snapshots because session IDs can be reused. Request elapsed time, wait time, session age, and transaction age are different measurements.

## Historical workload assessment

Run the numbered sections in [Workload-assessment.sql](Workload-assessment.sql) **separately**, connected to each relevant Warehouse.

**Update the date range before executing.** The checked-in default is September 14, 2026 at 00:00 UTC, inclusive, through September 28, 2026 at 00:00 UTC, exclusive. Replace both date literals in **every** windowed section you run; there is no shared global parameter.

For example, a one-day collection window is:

```sql
CAST('2026-09-28T00:00:00' AS datetime2(6)) AS from_utc,
CAST('2026-09-29T00:00:00' AS datetime2(6)) AS to_utc
```

| Section | Output |
| --- | --- |
| 1 | Warehouse and diagnostic-session context. |
| 2 | Available columns in `queryinsights.exec_requests_history` and `queryinsights.sql_pool_insights`. |
| 3 | Full visible request detail for requests completed within the window, including requests submitted before it. |
| 4 | Hourly submission cohorts by application, SQL pool, and statement type, with outcomes and successful-request latency percentiles. |
| 5 | Query-shape ranking by query hash, application, pool, statement type, and status. |
| 6 | Peak observed historical request overlap per SQL pool. |
| 7 | SQL-pool configuration and pressure events, including the last retained pre-window event per pool. |
| 8 | Optional SQL-text sample for an explicitly selected query hash; commented out by default. |
| 9 | Daily submission-cohort summary by SQL pool, including successful-request p50/p95 latency. |

For large histories, collect one day at a time and export all result rows rather than copying a truncated results grid. Section 3 is the primary detailed export; section 8 deliberately limits SQL-text samples to 20 rows and requires approval before use.

### Interpretation limits

- Query Insights retains 30 days of user-context request history. Publication can lag; the script notes delays of 15 minutes or more under heavy load. Running or unpublished requests are absent from historical calculations.
- Completion-window detail and submission-window cohorts answer different questions. Requests submitted before the window may appear in section 3 but not in sections 4, 5, or 9.
- Allocated CPU time is **not actual CPU utilization or billed capacity units**. Whole-request metrics assigned to submission buckets are not instantaneous utilization.
- Historical overlap counts request intervals, including time spent waiting. It is **not worker concurrency** or a count of simultaneously executing tasks.
- SQL-pool pressure rows are state-change events, not periodic samples. A fraction of rows marked under pressure is not a percentage of time under pressure.
- Missing metrics remain unknown. SQL aggregates can ignore `NULL` values; missing data must not be reported as zero.

## Troubleshooting runbook

Open `index.html` in a browser to read the runbook; no package installation or build is required.

The runbook provides symptom-driven investigation paths, copyable SQL, expandable sections, light/dark themes, and print support. It is a reference page, not a live dashboard and does not connect to your Warehouse.

**Current packaging limitations:** Some navigation and cross-reference links in `index.html` retain absolute `file:///` paths from the author's machine, so those links may not work on another computer or when hosted. The workload script also references `COLLECTION-GUIDE.txt`, which is not included in this repository. Review the script comments and the collection guidance above before running it.

## Safety and handling diagnostic data

The standalone SQL scripts use read-only queries. They do not kill sessions, commit or roll back application transactions, change workload settings, or create monitoring objects. Read-only queries still consume resources; choose a collection scope and cadence appropriate to the environment.

Results can contain identities, application names, resource descriptions, query labels, and operational metadata. Optional SQL text can contain confidential literals or credentials. Review and redact exports locally before sharing, and never commit credentials, connection strings, or raw customer diagnostic results to this repository.

Treat findings as evidence for investigation, not authorization for remediation. Confirm the affected application and transaction owner before taking any corrective action.

## References

- [Monitoring overview](https://learn.microsoft.com/en-us/fabric/data-warehouse/monitoring-overview)
- [Monitor connections, sessions, and requests using DMVs](https://learn.microsoft.com/en-us/fabric/data-warehouse/monitor-using-dmv)
- [Troubleshoot query blocking](https://learn.microsoft.com/en-us/fabric/data-warehouse/troubleshoot-query-blocking)
- [Query Insights](https://learn.microsoft.com/en-us/fabric/data-warehouse/query-insights)
- [Query Insights request history reference](https://learn.microsoft.com/en-us/sql/relational-databases/system-views/queryinsights-exec-requests-history-transact-sql?view=fabric)
- [SQL-pool insights reference](https://learn.microsoft.com/en-us/sql/relational-databases/system-views/queryinsights-sql-pool-insights-transact-sql?view=fabric)

## Contributing

Report issues or propose improvements through this repository's issues and pull requests. Include the affected script, expected behavior, relevant role/visibility limitations, and a sanitized reproduction. Keep diagnostic queries read-only and document changes to scope, thresholds, or interpretation.

## License

No license file is currently included in this repository. Consult the repository owner for usage and redistribution terms.
