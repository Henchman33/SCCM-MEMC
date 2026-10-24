;WITH CollectionMembers AS
(
    SELECT
        ResourceID,
        CollectionID
    FROM v_FullCollectionMembership
    WHERE CollectionID = 'P010010E'
),
PrimaryIP AS
(
    SELECT
        ResourceID,
        MIN(IP_Addresses0) AS IPAddress
    FROM v_RA_System_IPAddresses
    WHERE
        IP_Addresses0 NOT LIKE '%:%'
        AND IP_Addresses0 NOT LIKE '169.254.%'
    GROUP BY ResourceID
)
SELECT
    GETDATE() AS [Report Generated],

    COL.Name AS [Collection Name],

    SYS.Name0 AS [Computer Name],
    SYS.Resource_Domain_OR_Workgr0 AS [Domain],

    PIP.IPAddress AS [IPv4 Address],

    MAX(OS.Caption0) AS [Operating System],
    MAX(OS.Version0) AS [OS Version],
    MAX(OS.BuildNumber0) AS [OS Build],
    MAX(OS.OSArchitecture0) AS [Architecture],

    MAX(OS.LastBootUpTime0) AS [Last Reboot],

    DATEDIFF(
        DAY,
        MAX(OS.LastBootUpTime0),
        GETDATE()
    ) AS [Days Since Reboot],

    CASE
        WHEN DATEDIFF(
                DAY,
                MAX(OS.LastBootUpTime0),
                GETDATE()
            ) > 30
        THEN 'Reboot Required Review'
        ELSE 'OK'
    END AS [Reboot Status],

    CASE
        WHEN MAX(SYS.Client0) = 1 THEN 'Yes'
        ELSE 'No'
    END AS [SCCM Client Installed],

    COUNT(DISTINCT UI.ArticleID) AS [Missing KB Count],

    CASE
        WHEN MAX(UI.Severity) >= 10
             AND COUNT(DISTINCT UI.ArticleID) >= 5
            THEN 'Critical Risk'

        WHEN MAX(UI.Severity) >= 10
            THEN 'High Risk'

        WHEN MAX(UI.Severity) >= 8
             AND COUNT(DISTINCT UI.ArticleID) >= 10
            THEN 'High Risk'

        WHEN MAX(UI.Severity) >= 8
            THEN 'Moderate Risk'

        WHEN COUNT(DISTINCT UI.ArticleID) >= 15
            THEN 'Moderate Risk'

        WHEN COUNT(DISTINCT UI.ArticleID) >= 1
            THEN 'Minor Issues'

        ELSE 'Compliant'
    END AS [Patch Status],

    CASE
        WHEN MAX(UI.Severity) >= 10 THEN 'Critical'
        WHEN MAX(UI.Severity) >= 8 THEN 'Important'
        WHEN MAX(UI.Severity) >= 6 THEN 'Moderate'
        WHEN MAX(UI.Severity) >= 2 THEN 'Low'
        ELSE 'Unknown'
    END AS [Highest Severity],

    MAX(UI.DatePosted) AS [Newest Missing Patch Date],

    STRING_AGG(
        CONCAT(
            'KB',
            UI.ArticleID,
            ' - ',
            UI.Title
        ),
        CHAR(13) + CHAR(10)
    ) AS [Missing Updates]

FROM CollectionMembers CM

INNER JOIN v_Collection COL
    ON CM.CollectionID = COL.CollectionID

INNER JOIN v_R_System SYS
    ON CM.ResourceID = SYS.ResourceID

INNER JOIN v_GS_OPERATING_SYSTEM OS
    ON SYS.ResourceID = OS.ResourceID

INNER JOIN PrimaryIP PIP
    ON SYS.ResourceID = PIP.ResourceID

INNER JOIN v_Update_ComplianceStatusAll UCS
    ON SYS.ResourceID = UCS.ResourceID

INNER JOIN v_UpdateInfo UI
    ON UCS.CI_ID = UI.CI_ID

WHERE
    UCS.Status = 2
    AND UI.IsSuperseded = 0
    AND UI.IsDeployed = 1
    AND UI.ArticleID IS NOT NULL

    -- Last 2 months of updates
    AND UI.DatePosted >= DATEADD(MONTH,-2,GETDATE())

    -- Exclude common noise
    AND UI.ArticleID <> '890830'
    AND UI.Title NOT LIKE '%Preview%'
    AND UI.Title NOT LIKE 'All Server%'
    AND UI.Title NOT LIKE '%Itanium%'

GROUP BY
    COL.Name,
    SYS.Name0,
    SYS.Resource_Domain_OR_Workgr0,
    PIP.IPAddress

ORDER BY
    CASE
        WHEN MAX(UI.Severity) >= 10
             AND COUNT(DISTINCT UI.ArticleID) >= 5 THEN 1
        WHEN MAX(UI.Severity) >= 10 THEN 2
        WHEN MAX(UI.Severity) >= 8
             AND COUNT(DISTINCT UI.ArticleID) >= 10 THEN 3
        WHEN MAX(UI.Severity) >= 8 THEN 4
        WHEN COUNT(DISTINCT UI.ArticleID) >= 15 THEN 5
        WHEN COUNT(DISTINCT UI.ArticleID) >= 1 THEN 6
        ELSE 7
    END,
    [Missing KB Count] DESC,
    [Days Since Reboot] DESC,
    [Computer Name];
