/*******************************************************************************
 * Cluster Health (WSFC / Pacemaker) — as seen by SQL Server
 *
 * Purpose : Report the underlying cluster the AG/FCI rides on: cluster name and
 *           quorum type/state, member nodes & witnesses with their quorum votes
 *           and state, and the cluster networks visible to the instance.
 * Version : SQL Server 2016+ (build 13.x+). Windows (WSFC) and Linux
 *           (Pacemaker) clusters surface through these DMVs.
 * Safety  : READ-ONLY. No cluster, quorum, or vote changes.
 *
 * Sections:
 *   1. Instance Cluster Context (IsHadrEnabled / IsClustered)
 *   2. Cluster Identity & Quorum (sys.dm_hadr_cluster)
 *   3. Cluster Members — Nodes & Witness, votes & state
 *   4. Cluster Networks
 *
 * NOTE: Deeper WSFC inspection (Get-ClusterQuorum, Get-ClusterNode, NodeWeight)
 *       is done at the OS level via PowerShell — see references/failover-clustering.md.
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Instance Cluster Context
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SERVERPROPERTY('MachineName')               AS machine_name,
    SERVERPROPERTY('ServerName')                AS server_name,
    SERVERPROPERTY('IsClustered')               AS is_fci,            -- 1 = this instance is an FCI
    SERVERPROPERTY('IsHadrEnabled')             AS is_hadr_enabled,   -- 1 = Always On enabled
    SERVERPROPERTY('Edition')                   AS edition,
    SERVERPROPERTY('ProductVersion')            AS product_version;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Cluster Identity & Quorum
  sys.dm_hadr_cluster is populated when the instance is a WSFC/Pacemaker member
  (FCI or Always On). It is empty on a non-clustered, non-HADR instance.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.dm_hadr_cluster)
BEGIN
    SELECT
        cluster_name,
        quorum_type_desc,            -- NODE_MAJORITY / NODE_AND_DISK_MAJORITY / NODE_AND_FILE_SHARE_MAJORITY / DISK_ONLY / etc.
        quorum_state_desc            -- NORMAL_QUORUM / etc.
    FROM sys.dm_hadr_cluster;
END
ELSE
BEGIN
    SELECT 'This instance is not part of a WSFC/Pacemaker cluster (no FCI and Always On not '
         + 'cluster-backed). sys.dm_hadr_cluster is empty.' AS info_message;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Cluster Members — Nodes & Witness, quorum votes & state
  A node/witness with number_of_quorum_votes = 0 has had its vote removed
  (manually or by dynamic quorum). DOWN members may threaten quorum.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.dm_hadr_cluster_members)
BEGIN
    SELECT
        member_name                             AS node_or_witness,
        member_type_desc                        AS member_type,      -- WSFC_NODE / WSFC_DISK_WITNESS / WSFC_FILE_SHARE_WITNESS / WSFC_CLOUD_WITNESS
        member_state_desc                       AS member_state,     -- UP / DOWN
        number_of_quorum_votes                  AS quorum_votes
    FROM sys.dm_hadr_cluster_members
    ORDER BY member_type_desc, member_name;

    -- Quick total-vote sanity check (odd total is healthiest)
    SELECT
        SUM(number_of_quorum_votes)             AS total_quorum_votes,
        SUM(CASE WHEN member_state_desc = 'UP' THEN number_of_quorum_votes ELSE 0 END) AS votes_currently_up,
        CASE WHEN SUM(number_of_quorum_votes) % 2 = 0
             THEN 'EVEN total votes — ensure a witness is configured to break ties'
             ELSE 'Odd total votes — good'
        END                                     AS vote_parity_note
    FROM sys.dm_hadr_cluster_members;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Cluster Networks visible to the instance
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.dm_hadr_cluster_networks)
BEGIN
    SELECT
        member_name                             AS node_name,
        network_subnet_ip,
        network_subnet_ipv4_mask,
        network_subnet_prefix_length,
        is_public,
        is_ipv4
    FROM sys.dm_hadr_cluster_networks
    ORDER BY member_name, network_subnet_ip;
END;
