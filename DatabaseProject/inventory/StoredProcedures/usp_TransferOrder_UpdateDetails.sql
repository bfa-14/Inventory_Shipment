/* 13.5 "SAVE DETAILS" OF AN ORDER THAT IS NO LONGER A DRAFT (rule T9): on a released order still under way (shown
   Released, Partly dispatched, Dispatched, Partly received) Expected arrival (not before the order date), Reference
   No. and Notes; on a received, closed or cancelled one the notes only - the dates and the reference the postings were
   made against stay as they were. A draft is changed with Save, an order waiting for approval is locked (Blocks,
   UpdateDetails). Nothing changed: nothing written. Audit DetailsUpdated names what changed. */
CREATE   PROCEDURE inventory.usp_TransferOrder_UpdateDetails
    @Id              INT,
    @ExpectedArrival DATE           = NULL,
    @ReferenceNo     NVARCHAR(100)  = NULL,
    @Notes           NVARCHAR(1000) = NULL,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @DocDate DATE, @OldEta DATE, @OldRef NVARCHAR(100),
            @OldNotes NVARCHAR(1000), @Shown NVARCHAR(20), @EtaChanged BIT, @RefChanged BIT, @NotesChanged BIT,
            @Details NVARCHAR(1000);

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @DocDate = DocumentDate, @OldEta = ExpectedArrival, @OldRef = ReferenceNo, @OldNotes = Notes
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'UpdateDetails' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        SELECT @Shown = st.DisplayStatus FROM inventory.fn_TransferOrder_State(@Id) st;
        -- the comparisons are exact (a case change of the reference or the notes is a change)
        SET @EtaChanged   = CASE WHEN ISNULL(@ExpectedArrival, '19000101') <> ISNULL(@OldEta, '19000101') THEN 1 ELSE 0 END;
        SET @RefChanged   = CASE WHEN ISNULL(@ReferenceNo, N'') COLLATE Latin1_General_BIN2 <> ISNULL(@OldRef, N'') COLLATE Latin1_General_BIN2 THEN 1 ELSE 0 END;
        SET @NotesChanged = CASE WHEN ISNULL(@Notes, N'') COLLATE Latin1_General_BIN2 <> ISNULL(@OldNotes, N'') COLLATE Latin1_General_BIN2 THEN 1 ELSE 0 END;

        IF (@Status = 3 OR @Shown IN (N'Received', N'Closed')) AND (@EtaChanged = 1 OR @RefChanged = 1)
            THROW 62010, 'Only the notes can change on a received, closed or cancelled transfer order.', 1;
        IF @EtaChanged = 1 AND @ExpectedArrival < @DocDate
            THROW 62000, 'Expected arrival cannot be before the order date.', 1;

        IF @EtaChanged = 1 OR @RefChanged = 1 OR @NotesChanged = 1
        BEGIN
            SET @Details = STUFF(
                  CASE WHEN @EtaChanged = 1 THEN N'; Expected arrival ' + ISNULL(CONVERT(NVARCHAR(10), @OldEta, 103), N'none')
                                                 + N' -> ' + ISNULL(CONVERT(NVARCHAR(10), @ExpectedArrival, 103), N'none') ELSE N'' END
                + CASE WHEN @RefChanged = 1 THEN N'; Reference No. ' + ISNULL(@OldRef, N'none') + N' -> ' + ISNULL(@ReferenceNo, N'none') ELSE N'' END
                + CASE WHEN @NotesChanged = 1 THEN N'; Notes' ELSE N'' END, 1, 2, N'');

            UPDATE inventory.TransferOrders
            SET ExpectedArrival = @ExpectedArrival, ReferenceNo = @ReferenceNo, Notes = @Notes,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, N'DetailsUpdated', LEFT(@Details, 500), @UserId);
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

