/* 13.4 SAVE A DRAFT: creates one, or replaces an existing draft, lines and all (the lines may be empty on a draft).
   The checks, in order (62000 unless said): the TRO type is active (62008); an existing order is still editable
   (Blocks, Edit: a draft); the order date (required, at most one day ahead: the reader's time zone); the warehouses
   (inventory.usp_TransferOrder_CheckWarehouses: the one place of those rules); Expected arrival not before the order
   date; each line by line number (item, active, its unit, Ordered above 0).
   The order's branch follows From at every save (D2); the NUMBER is given at the first save by From's branch when the
   TRO type numbers documents at their first save (NumberOnPost 0), else at release, and then keeps the branch it got.
   Each line keeps its unit's packing formula of the moment it is saved (Ordered in pcs never changes under it). No
   result set: @NewId = the order. */
-- Re-created (92) from the body of script 90: + the From the request names must be the editor's (W7), checked after
-- the warehouse rules and before the number is taken (a refusal creates nothing and uses no number); the To may be any
-- warehouse (A9). 91's usp_TransferOrder_CreateFromLevels saves through it.
CREATE   PROCEDURE inventory.usp_TransferOrder_Save
    @Id              INT            = NULL,
    @DocumentDate    DATE,
    @FromWarehouseId INT,
    @ToWarehouseId   INT,
    @ExpectedArrival DATE           = NULL,
    @ReferenceNo     NVARCHAR(100)  = NULL,
    @Notes           NVARCHAR(1000) = NULL,
    @Lines           inventory.tvp_TransferOrderLine READONLY,
    @RowVersion      BINARY(8)      = NULL,
    @UserId          INT            = NULL,
    @NewId           INT            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ReferenceNo = NULLIF(LTRIM(RTRIM(@ReferenceNo)), N'');
    SET @Notes = NULLIF(LTRIM(RTRIM(@Notes)), N'');

    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @TypeId INT, @TypeActive BIT, @NumberOnPost BIT,
            @BranchId INT, @Number NVARCHAR(30), @LineCount INT, @Pcs INT,
            @Tomorrow DATE = DATEADD(DAY, 1, CAST(SYSUTCDATETIME() AS DATE));

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Id IS NOT NULL
        BEGIN
            SELECT @Status = Status, @Number = DocumentNumber
            FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
            IF @Status IS NOT NULL AND @RowVersion IS NOT NULL
               AND NOT EXISTS (SELECT 1 FROM inventory.TransferOrders WHERE Id = @Id AND RowVersion = @RowVersion)
                THROW 62004, 'This transfer order was modified by another user. Reload the page and try again.', 1;
        END

        -- 1. The type: switched off, no order is saved (the sentence of Blocks Seq 33)
        SELECT @TypeId = Id, @TypeActive = IsActive, @NumberOnPost = NumberOnPost FROM inventory.DocumentTypes WHERE Code = N'TRO';
        IF @TypeId IS NULL THROW 62008, 'The document type TRO is missing: restart the API so that script 90 creates it.', 1;
        IF @TypeActive = 0
        BEGIN
            SET @Msg = N'Transfer orders are switched off: the document type TRO is inactive (Configuration ' + NCHAR(8250) + N' Document Types).';
            THROW 62008, @Msg, 1;
        END

        -- 2. An existing order: only a draft is saved (Blocks, Edit; an unknown id is its Seq 1, "not found")
        IF @Id IS NOT NULL
        BEGIN
            SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
            FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
            WHERE b.Action = N'Edit' AND b.Message IS NOT NULL
            ORDER BY b.Seq;
            IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;
        END

        -- 3. The order date (one day of tolerance ahead: the reader's time zone)
        IF @DocumentDate IS NULL THROW 62000, 'Order date is required.', 1;
        IF @DocumentDate > @Tomorrow THROW 62000, 'The order date cannot be in the future.', 1;

        -- 4. From and To
        EXEC inventory.usp_TransferOrder_CheckWarehouses @FromWarehouseId, @ToWarehouseId;

        -- (92) 4b. The From the request names must be the editor's (an existing order's STORED From is Blocks' Edit, step 2);
        --      the To may be any warehouse (A9)
        SET @Msg = security.fn_User_WarehouseRefusal(@UserId, CAST(@FromWarehouseId AS NVARCHAR(12)));
        IF @Msg IS NOT NULL THROW 50010, @Msg, 1;

        -- 5. Expected arrival
        IF @ExpectedArrival < @DocumentDate THROW 62000, 'Expected arrival cannot be before the order date.', 1;

        -- 6. The lines, the first failing by line number
        SET @Msg = NULL;
        SELECT TOP (1) @Msg = N'Line ' + CAST(l.LineNumber AS NVARCHAR(10)) + N': ' +
               CASE WHEN i.Id IS NULL       THEN N'item not found.'
                    WHEN i.IsActive = 0     THEN N'item ' + i.ItemCode + N' is inactive.'
                    WHEN iu.Id IS NULL      THEN N'the unit does not belong to item ' + i.ItemCode + N'.'
                    WHEN l.Quantity <= 0    THEN N'Ordered must be a whole number above 0.'
                    ELSE N'Ordered is too large.' END        -- Ordered in pcs above an INT (never typed in practice)
        FROM @Lines l
        LEFT JOIN inventory.Items i      ON i.Id = l.ItemId
        LEFT JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId
        WHERE i.Id IS NULL OR i.IsActive = 0 OR iu.Id IS NULL OR l.Quantity <= 0
           OR CAST(l.Quantity AS BIGINT) * iu.PackingFormula > 2147483647
        ORDER BY l.LineNumber;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;
        -- the order's total in pcs is an INT too (lines each within it can add up past it)
        IF (SELECT SUM(CAST(l.Quantity AS BIGINT) * iu.PackingFormula) FROM @Lines l
            INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId) > 2147483647
            THROW 62000, 'The order is too large: its lines add up to more pieces than can be counted. Split it into several orders.', 1;

        -- The writes
        SELECT @BranchId = BranchId FROM masterdata.Warehouses WHERE Id = @FromWarehouseId;
        SELECT @LineCount = COUNT(*), @Pcs = ISNULL(SUM(l.Quantity * iu.PackingFormula), 0)
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

        IF @Id IS NULL
        BEGIN
            IF @NumberOnPost = 0
                EXEC inventory.usp_DocumentType_NextNumber @Code = N'TRO', @DocumentNumber = @Number OUTPUT, @BranchId = @BranchId;

            INSERT INTO inventory.TransferOrders (DocumentTypeId, DocumentNumber, DocumentDate, BranchId, FromWarehouseId, ToWarehouseId,
                                                  ExpectedArrival, ReferenceNo, Notes, Status, TotalLines, TotalOrderedBase, CreatedBy)
            VALUES (@TypeId, @Number, @DocumentDate, @BranchId, @FromWarehouseId, @ToWarehouseId,
                    @ExpectedArrival, @ReferenceNo, @Notes, 1, @LineCount, @Pcs, @UserId);
            SET @Id = SCOPE_IDENTITY();

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, N'Created', CASE WHEN @Number IS NOT NULL THEN N'Created as ' + @Number ELSE N'Created (numbered when released)' END, @UserId);
        END
        ELSE
        BEGIN
            UPDATE inventory.TransferOrders
            SET DocumentDate = @DocumentDate, BranchId = @BranchId, FromWarehouseId = @FromWarehouseId, ToWarehouseId = @ToWarehouseId,
                ExpectedArrival = @ExpectedArrival, ReferenceNo = @ReferenceNo, Notes = @Notes,
                TotalLines = @LineCount, TotalOrderedBase = @Pcs,
                UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
            WHERE Id = @Id;

            DELETE FROM inventory.TransferOrderLines WHERE TransferOrderId = @Id;

            INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
            VALUES (@Id, N'Updated', CAST(@LineCount AS NVARCHAR(10)) + N' line(s), ' + CAST(@Pcs AS NVARCHAR(20)) + N' pcs', @UserId);
        END

        INSERT INTO inventory.TransferOrderLines (TransferOrderId, LineNumber, ItemId, ItemUnitId, Quantity, PackingFormula, Notes)
        SELECT @Id, l.LineNumber, l.ItemId, l.ItemUnitId, l.Quantity, iu.PackingFormula, NULLIF(LTRIM(RTRIM(l.Notes)), N'')
        FROM @Lines l
        INNER JOIN inventory.ItemUnits iu ON iu.Id = l.ItemUnitId AND iu.ItemId = l.ItemId;

        COMMIT TRANSACTION;
        SET @NewId = @Id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

