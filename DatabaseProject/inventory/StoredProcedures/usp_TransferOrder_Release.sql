/* 13.8 RELEASE (Blocks, Release): the order is locked and its goods can be dispatched. When the TRO type asks for
   approval, only an approver gets past Blocks (Seq 37), and his Release is an approval as well: "Approve & release",
   approved directly by him (ApprovedAndReleased). The number is given now when the draft has none (TRO numbering at
   release), by From's branch; a rejection shown on the draft is cleared.
   Result set 1 = warnings, released all the same (nothing is reserved, FB rule 16): per item of the order whose
   released orders from From, this one now included, need more than From holds - "TVS-APACHE-160: the released orders
   from LKS-01 need 120 pcs; LKS-01 holds 80.", in line order. */
CREATE   PROCEDURE inventory.usp_TransferOrder_Release
    @Id         INT,
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @Number NVARCHAR(30), @FromId INT, @ToId INT,
            @NeedsApproval BIT, @WithApproval BIT, @Now DATETIME2(3) = SYSUTCDATETIME(), @Lines INT, @Pcs INT;
    DECLARE @W TABLE (Seq INT IDENTITY(1,1) PRIMARY KEY, Message NVARCHAR(400) NOT NULL);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @Number = DocumentNumber, @FromId = FromWarehouseId, @ToId = ToWarehouseId
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'Release' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SELECT @NeedsApproval = dt.NeedsApproval
        FROM inventory.TransferOrders o INNER JOIN inventory.DocumentTypes dt ON dt.Id = o.DocumentTypeId
        WHERE o.Id = @Id;
        SET @WithApproval = CASE WHEN @NeedsApproval = 1 AND security.fn_UserHasPermission(@UserId, N'inventory.transfers.approve') = 1
                                 THEN 1 ELSE 0 END;

        IF @Number IS NULL
        BEGIN
            DECLARE @FromBranchId INT = (SELECT BranchId FROM masterdata.Warehouses WHERE Id = @FromId);
            EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRO', @DocumentNumber = @Number OUTPUT, @BranchId = @FromBranchId;
        END

        UPDATE inventory.TransferOrders
        SET Status = 2, DocumentNumber = @Number,
            ReleasedAtUtc = @Now, ReleasedBy = @UserId,
            ApprovedAtUtc = CASE WHEN @WithApproval = 1 THEN @Now END,
            ApprovedBy    = CASE WHEN @WithApproval = 1 THEN @UserId END,
            ApprovedDirectly = @WithApproval,
            RejectedAtUtc = NULL, RejectedBy = NULL, RejectReason = NULL,
            UpdatedAtUtc = @Now, UpdatedBy = @UserId
        WHERE Id = @Id;

        SELECT @Lines = COUNT(*), @Pcs = ISNULL(SUM(OrderedBase), 0) FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;
        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        SELECT @Id, CASE WHEN @WithApproval = 1 THEN N'ApprovedAndReleased' ELSE N'Released' END,
               LEFT(@Number + CASE WHEN @WithApproval = 1 THEN N' approved and released directly: ' ELSE N' released: ' END
                    + CAST(@Lines AS NVARCHAR(10)) + N' line(s), ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs, '
                    + fw.WarehouseCode + N' -> ' + tw.WarehouseCode + N'.', 500), @UserId
        FROM masterdata.Warehouses fw CROSS JOIN masterdata.Warehouses tw
        WHERE fw.Id = @FromId AND tw.Id = @ToId;

        -- The warnings: every released order from From, this one included now
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
END

GO

