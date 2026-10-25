/* 13.25 CREATE A RETURN (Blocks, CreateReturn: something received that the returns not cancelled do not already take
   back; FB decision 26, D15): a new DRAFT through Save's insert path - From = the original's To, To = its From (the
   warehouse rules apply: one made inactive since refuses), dated today, no Expected arrival, Reference "Return of
   {No}", linked to the original (ReturnOfOrderId). One line per item, in the order of its first line on the original:
   ReturnableBase = what the original received of the item - what its returns not cancelled (drafts included) already
   order of it, when above 0; in the unit of the item's first line when ReturnableBase is a whole number of that unit
   (its packing formula unchanged since: Save takes the unit's current one), else in the base unit; that line's notes.
   The original's counters never change. Audit ReturnCreated on the new order ("Return of {No}"), ReturnOf on the
   original ("Return {TRO} created"). @NewId = the new draft. */
CREATE   PROCEDURE inventory.usp_TransferOrder_CreateReturn
    @Id     INT,
    @UserId INT = NULL,
    @NewId  INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @NewId = NULL;
    DECLARE @Msg NVARCHAR(400), @ErrNo INT, @Status TINYINT, @No NVARCHAR(30), @FromId INT, @ToId INT,
            @Today DATE = CAST(SYSUTCDATETIME() AS DATE), @Reference NVARCHAR(100), @NewNumber NVARCHAR(30);
    DECLARE @Lines inventory.tvp_TransferOrderLine;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @Status = Status, @No = DocumentNumber, @FromId = FromWarehouseId, @ToId = ToWarehouseId
        FROM inventory.TransferOrders WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;

        SELECT TOP (1) @ErrNo = b.ErrorNumber, @Msg = b.Message
        FROM inventory.fn_TransferOrder_Blocks(@Id, @UserId) b
        WHERE b.Action = N'CreateReturn' AND b.Message IS NOT NULL
        ORDER BY b.Seq;
        IF @Msg IS NOT NULL THROW @ErrNo, @Msg, 1;

        -- What can still be returned, per item (the rule of Blocks Seq 121)
        DECLARE @X TABLE (ItemId INT NOT NULL PRIMARY KEY, FirstLine INT NOT NULL, Returnable INT NOT NULL);
        INSERT INTO @X (ItemId, FirstLine, Returnable)
        SELECT r.ItemId, r.FirstLine,
               r.Received - ISNULL((SELECT SUM(rl.OrderedBase)
                                    FROM inventory.TransferOrderLines rl
                                    INNER JOIN inventory.TransferOrders ro ON ro.Id = rl.TransferOrderId
                                    WHERE ro.ReturnOfOrderId = @Id AND ro.Status <> 3 AND rl.ItemId = r.ItemId), 0)
        FROM (SELECT l.ItemId, FirstLine = MIN(l.LineNumber), Received = SUM(l.ReceivedBase)
              FROM inventory.TransferOrderLines l
              WHERE l.TransferOrderId = @Id
              GROUP BY l.ItemId) r;
        DELETE FROM @X WHERE Returnable <= 0;

        -- an item without a base unit cannot take a quantity that is not a whole number of its first line's unit
        SELECT TOP (1) @Msg = N'Item ' + i.ItemCode + N' has no base unit: give it one in Item Definition, then create the return.'
        FROM @X x
        INNER JOIN inventory.TransferOrderLines fl ON fl.TransferOrderId = @Id AND fl.LineNumber = x.FirstLine
        INNER JOIN inventory.ItemUnits fu          ON fu.Id = fl.ItemUnitId
        INNER JOIN inventory.Items i               ON i.Id = x.ItemId
        WHERE NOT (x.Returnable % fl.PackingFormula = 0 AND fu.PackingFormula = fl.PackingFormula)
          AND NOT EXISTS (SELECT 1 FROM inventory.ItemUnits bu WHERE bu.ItemId = x.ItemId AND bu.IsBaseUnit = 1)
        ORDER BY x.FirstLine;
        IF @Msg IS NOT NULL THROW 62000, @Msg, 1;

        INSERT INTO @Lines (LineNumber, ItemId, ItemUnitId, Quantity, Notes)
        SELECT ROW_NUMBER() OVER (ORDER BY x.FirstLine), x.ItemId,
               CASE WHEN u.WholeUnits = 1 THEN fl.ItemUnitId ELSE bu.Id END,
               CASE WHEN u.WholeUnits = 1 THEN x.Returnable / fl.PackingFormula ELSE x.Returnable END,
               fl.Notes
        FROM @X x
        INNER JOIN inventory.TransferOrderLines fl ON fl.TransferOrderId = @Id AND fl.LineNumber = x.FirstLine
        INNER JOIN inventory.ItemUnits fu          ON fu.Id = fl.ItemUnitId
        CROSS APPLY (SELECT WholeUnits = CASE WHEN x.Returnable % fl.PackingFormula = 0 AND fu.PackingFormula = fl.PackingFormula
                                              THEN 1 ELSE 0 END) u
        OUTER APPLY (SELECT TOP (1) b.Id FROM inventory.ItemUnits b WHERE b.ItemId = x.ItemId AND b.IsBaseUnit = 1) bu;

        -- The new draft: Save's own insert path (its checks, its number, its Created audit row), in this transaction
        SET @Reference = N'Return of ' + ISNULL(@No, N'a transfer order');
        EXEC inventory.usp_TransferOrder_Save @Id = NULL, @DocumentDate = @Today, @FromWarehouseId = @ToId, @ToWarehouseId = @FromId,
             @ExpectedArrival = NULL, @ReferenceNo = @Reference, @Notes = NULL, @Lines = @Lines, @RowVersion = NULL,
             @UserId = @UserId, @NewId = @NewId OUTPUT;

        UPDATE inventory.TransferOrders SET ReturnOfOrderId = @Id WHERE Id = @NewId;
        SELECT @NewNumber = DocumentNumber FROM inventory.TransferOrders WHERE Id = @NewId;

        INSERT INTO inventory.TransferOrderAudit (TransferOrderId, Action, Details, UserId)
        VALUES (@NewId, N'ReturnCreated', LEFT(@Reference, 500), @UserId),
               (@Id, N'ReturnOf', CASE WHEN @NewNumber IS NOT NULL THEN N'Return ' + @NewNumber + N' created'
                                       ELSE N'Return created (a draft, numbered when released)' END, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

