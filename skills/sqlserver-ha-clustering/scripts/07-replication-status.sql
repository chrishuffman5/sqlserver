/*******************************************************************************
 * Replication — Status & Latency Hints
 *
 * Purpose : Detect this instance's replication roles (Publisher / Distributor /
 *           Subscriber), list publications/articles/subscriptions where the
 *           catalog views exist, and surface undistributed-command / latency
 *           hints. Guards gracefully when replication is not installed/configured.
 * Version : SQL Server 2016+ (build 13.x+).
 * Safety  : READ-ONLY. No replication configuration or agent changes.
 *
 * Sections:
 *   1. Replication Role Detection (database flags + distributor)
 *   2. Distribution Database Discovery
 *   3. Publications & Articles (publisher side)
 *   4. Subscriptions
 *   5. Undistributed Commands / Latency Hints (distribution DB)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Replication Role Detection
  sys.databases flags reveal publish/subscribe roles; is_distributor marks the
  distribution database.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (
    SELECT 1 FROM sys.databases
    WHERE is_published = 1 OR is_subscribed = 1
       OR is_merge_published = 1 OR is_distributor = 1
)
BEGIN
    SELECT
        name                                    AS database_name,
        is_published                            AS transactional_or_snapshot_publisher,
        is_merge_published                      AS merge_publisher,
        is_subscribed                           AS subscriber,
        is_distributor                          AS is_distribution_db
    FROM sys.databases
    WHERE is_published = 1 OR is_subscribed = 1
       OR is_merge_published = 1 OR is_distributor = 1
    ORDER BY name;
END
ELSE
BEGIN
    SELECT 'No replication roles detected on this instance '
         + '(no published, subscribed, merge-published, or distributor databases).' AS info_message;
    -- Continue: the instance may still be a remote distributor; checked below.
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Distribution Database Discovery
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.databases WHERE is_distributor = 1)
BEGIN
    SELECT name AS distribution_database, create_date, state_desc
    FROM sys.databases
    WHERE is_distributor = 1;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Publications & Articles (publisher side)
  syspublications / sysarticles live in each PUBLISHED user database; query only
  when they exist. We iterate published DBs dynamically and guard each object.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.databases WHERE is_published = 1 OR is_merge_published = 1)
BEGIN
    DECLARE @db SYSNAME, @sql NVARCHAR(MAX);
    DECLARE pub_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE (is_published = 1 OR is_merge_published = 1) AND state = 0;  -- ONLINE
    OPEN pub_cur;
    FETCH NEXT FROM pub_cur INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @sql = N'
            IF OBJECT_ID(' + QUOTENAME(@db + N'.dbo.syspublications','''') + N') IS NOT NULL
            SELECT ' + QUOTENAME(@db,'''') + N' AS published_db,
                   p.name AS publication, p.description, p.status,
                   (SELECT COUNT(*) FROM ' + QUOTENAME(@db) + N'.dbo.sysarticles a
                    WHERE a.pubid = p.pubid) AS article_count
            FROM ' + QUOTENAME(@db) + N'.dbo.syspublications AS p;';
        EXEC sys.sp_executesql @sql;
        FETCH NEXT FROM pub_cur INTO @db;
    END;
    CLOSE pub_cur;
    DEALLOCATE pub_cur;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Subscriptions (distribution DB view of subscriptions)
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.databases WHERE is_distributor = 1)
   AND OBJECT_ID('distribution.dbo.MSsubscriptions') IS NOT NULL
BEGIN
    SELECT
        s.publisher_db,
        s.subscriber_db,
        s.subscription_type,                    -- 0=Push, 1=Pull, 2=Anonymous
        CASE s.subscription_type WHEN 0 THEN 'Push' WHEN 1 THEN 'Pull' WHEN 2 THEN 'Anonymous' END AS sub_kind,
        s.status,                               -- 0=Inactive,1=Subscribed,2=Active
        s.subscription_time
    FROM distribution.dbo.MSsubscriptions AS s
    ORDER BY s.publisher_db, s.subscriber_db;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Undistributed Commands / Latency Hints
  A growing undistributed-command backlog means the distribution agent (or the
  subscriber) cannot keep up. MSdistribution_status summarizes pending commands.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.databases WHERE is_distributor = 1)
   AND OBJECT_ID('distribution.dbo.MSdistribution_status') IS NOT NULL
BEGIN
    SELECT
        ds.article_id,
        ds.agent_id,
        ds.UndelivCmdsInDistDB                  AS undelivered_commands,
        ds.DelivCmdsInDistDB                    AS delivered_commands
    FROM distribution.dbo.MSdistribution_status AS ds
    WHERE ds.UndelivCmdsInDistDB > 0
    ORDER BY ds.UndelivCmdsInDistDB DESC;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Latency-measurement note (templates — run deliberately on the PUBLISHER):
    -- Post a tracer token and read its latency history via Replication Monitor or:
    --   EXEC sys.sp_posttracertoken @publication = N'YourPublication';
    --   EXEC distribution.dbo.sp_replmonitorsubscriptionpendingcmds ...;
──────────────────────────────────────────────────────────────────────────────*/
