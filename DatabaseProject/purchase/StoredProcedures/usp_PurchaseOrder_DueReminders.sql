-- was last sent (event 1, 2 or 3; before script 42: the request date of script 26). One transaction per order; an
-- order without approver is skipped (no event), another failure is reported as an informational message and the
-- order is tried again at the next call. Returns the rows of usp_PurchaseOrder_RequestApproval for every reminded
-- order, plus PurchaseDocumentId and WaitingSinceUtc. Calling it again at once returns nothing.
CREATE   PROCEDURE purchase.usp_PurchaseOrder_DueReminders
    @MaxOrders INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @MaxOrders IS NULL OR @MaxOrders < 1 SET @MaxOrders = 50;

    DECLARE @Hours INT = ISNULL((SELECT ReminderHours FROM purchase.ApprovalSettings WHERE Id = 1), 0);

    CREATE TABLE #IssuedLinks
    (
        PurchaseDocumentId INT NOT NULL, UserId INT NOT NULL, FullName NVARCHAR(100) NOT NULL, Email NVARCHAR(256) NULL,
        Token VARCHAR(64) NULL, ExpiresAtUtc DATETIME2(3) NULL, RequestNo INT NOT NULL, Channel NVARCHAR(10) NOT NULL,
        CanApproveInApp BIT NOT NULL, SendEmail BIT NOT NULL
    );
    CREATE TABLE #Due (PurchaseDocumentId INT NOT NULL PRIMARY KEY, WaitingSinceUtc DATETIME2(3) NULL, LastSentUtc DATETIME2(3) NULL);

    IF @Hours > 0
        INSERT INTO #Due (PurchaseDocumentId, WaitingSinceUtc, LastSentUtc)
        SELECT TOP (@MaxOrders) d.Id, w.WaitingSinceUtc, w.LastSentUtc
        FROM purchase.PurchaseDocuments d
        INNER JOIN inventory.DocumentTypes dt ON dt.Id = d.DocumentTypeId AND dt.Code = N'PO'
        CROSS APPLY (SELECT WaitingSinceUtc = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                                        WHERE e.PurchaseDocumentId = d.Id AND e.EventType = 1), d.ApprovalRequestedAtUtc),
                            LastSentUtc = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                                    WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)), d.ApprovalRequestedAtUtc)) w
        WHERE d.Status = 5
          AND w.LastSentUtc < DATEADD(HOUR, -@Hours, SYSUTCDATETIME())
        ORDER BY w.LastSentUtc, d.Id;

    DECLARE @Id INT, @LastSent DATETIME2(3), @Err NVARCHAR(2048);
    DECLARE due CURSOR LOCAL FAST_FORWARD FOR SELECT PurchaseDocumentId FROM #Due ORDER BY LastSentUtc, PurchaseDocumentId;
    OPEN due;
    FETCH NEXT FROM due INTO @Id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- still waiting and still due (another API instance may have reminded it meanwhile)
            SET @LastSent = NULL;
            SELECT @LastSent = COALESCE((SELECT MAX(CAST(e.AtUtc AS DATETIME2(3))) FROM purchase.PurchaseOrderApprovalEvents e
                                         WHERE e.PurchaseDocumentId = d.Id AND e.EventType IN (1, 2, 3)), d.ApprovalRequestedAtUtc)
            FROM purchase.PurchaseDocuments d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.Id = @Id AND d.Status = 5;

            IF @LastSent < DATEADD(HOUR, -@Hours, SYSUTCDATETIME())
                EXEC purchase.usp_PurchaseOrder_IssueLinks @PurchaseDocumentId = @Id, @EventType = 2, @UserId = NULL;

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() <> 65015
            BEGIN
                SET @Err = N'Reminder of purchase order ' + CAST(@Id AS NVARCHAR(10)) + N' skipped: ' + ERROR_MESSAGE();
                RAISERROR (N'%s', 10, 1, @Err) WITH NOWAIT;
            END
        END CATCH

        FETCH NEXT FROM due INTO @Id;
    END
    CLOSE due;
    DEALLOCATE due;

    SELECT l.UserId, l.FullName, l.Email, l.Token, l.ExpiresAtUtc, l.RequestNo, l.Channel, l.CanApproveInApp, l.SendEmail,
           l.PurchaseDocumentId, d.WaitingSinceUtc
    FROM #IssuedLinks l
    INNER JOIN #Due d ON d.PurchaseDocumentId = l.PurchaseDocumentId
    ORDER BY d.LastSentUtc, l.PurchaseDocumentId, l.FullName;
END

GO

