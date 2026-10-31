/* 13.10 APPROVE (Blocks, Approve: the approval right, the Release checks). An order waiting for approval is released
   with the approver's name (Approved); a draft, when the TRO type asks for approval, is approved and released at once
   by him ("Approve & release": ApprovedDirectly, as his Release would). Self-approval is allowed, there is no
   threshold (D5); an order already waiting when the switch was turned off can still be approved (D14). The number is
   given now when the order has none.
   Result set 1 = Release's warnings; 2 = the requester to tell ("Approved: transfer order ..."): RequestedById,
   RequestedByName, RequestedByEmail - no row for a direct approval. */
CREATE   PROCEDURE inventory.usp_TransferOrder_Approve
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Number NVARCHAR(30), @FromId INT, @ToId INT,
            @RequestedBy INT, @Waiting BIT, @Now DATETIME2(3) = SYSUTCDATETIME(), @Lines INT, @Pcs INT;
    DECLARE @W TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Message NVARCHAR(400) NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Number = DocumentNumber, @FromId = FromWarehouseId, @ToId = ToWarehouseId,
               @RequestedBy = ApprovalRequestedBy
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Approve' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SET @Waiting = CASE WHEN @Status = 4 THEN 1 ELSE 0 END;    -- else a draft: Approve & release

        IF @Number IS NULL
        BEGIN
            DECLARE @FromBranchId INT = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @FromId);
            EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRO', @DocumentNumber = @Number OUTPUT, @BranchId = @FromBranchId;
        END

        UPDATE inventory.TransferOrders
        SET Status = 2, DocumentNumber = @Number,
            ApprovedAtUtc = @Now, ApprovedBy = @UserId, ApprovedDirectly = CASE WHEN @Waiting = 1 THEN 0 ELSE 1 END,
            ReleasedAtUtc = @Now, ReleasedBy = @UserId,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        SELECT @Lines = COUNT(*), @Pcs = ISNULL(SUM(OrderedBase), 0) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        SELECT @Id, CASE WHEN @Waiting = 1 THEN N'Approved' ELSE N'ApprovedAndReleased' END,
               LEFT(@Number + CASE WHEN @Waiting = 1 THEN N' approved and released: ' ELSE N' approved and released directly: ' END
                    + CAST(@Lines AS NVARCHAR(10)) + N' line(s), ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs, '
                    + fw.WarehouseCode + N' -> ' + tw.WarehouseCode + N'.', 500), @UserId
        FROM masterdata.Warehouses fw CROSS JOIN masterdata.Warehouses tw
        WHERE fw.Id = @FromId AND tw.Id = @ToId;

        -- Release's warnings: every released order from From, this one included now
        INSERT INTO @W (Message)
        SELECT LEFT(i.ItemCode + N': the released orders from ' + fw.WarehouseCode + N' need ' + CAST(p.OutToDispatchBase AS NVARCHAR(20))
                    + N' pcs; ' + fw.WarehouseCode + N' holds ' + CAST(p.OnHandBase AS NVARCHAR(20)) + N'.', 400)
        FROM (SELECT ItemId, FirstLine = MIN(LineNumber) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id GROUP BY ItemId) x
        INNER JOIN inventory.Items i        ON i.Id = x.ItemId
        INNER JOIN masterdata.Warehouses fw ON fw.Id = @FromId
        CROSS APPLY inventory.fn_TransferPosition(x.ItemId, @FromId, NULL) p
        WHERE p.OutToDispatchBase > p.OnHandBase
        ORDER BY x.FirstLine;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH

    SELECT Message FROM @W ORDER BY Seq;

    SELECT RequestedById = u.Id, RequestedByName = u.FullName, RequestedByEmail = u.Email
    FROM security.Users u
    WHERE @Waiting = 1 AND u.Id = @RequestedBy;
END

GO

