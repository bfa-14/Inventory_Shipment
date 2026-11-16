SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* =====================================================================================
   Inventory_Shipment - 112: MASTER DATA - ONE PORT PER PLACE (THE DUPLICATE PORTS MERGED)

   Script 24 seeds Dar es Salaam as TZDAR and Lubumbashi as CDLUB; the data migration had already made them as TZ-DAR
   and CD-LUB, and every container, movement and stage uses those. The pickers showed each place twice.

     1. For each pair (TZ-DAR -> TZDAR, CD-LUB -> CDLUB): when both rows exist and the seeded one is used nowhere
        (containers, movements, container events, shipment stages, BIVAC port costs), the seeded row is deleted and
        the used row takes its code. The used row keeps its Id, so every document stays as it is; script 24's seed,
        run at every start, then finds its code and adds nothing.
        A seeded row that is used is left alone (PRINT): the two are then merged by hand.

   Errors: no new number. Requires script 24. Idempotent: once merged there is nothing left to do.
   ===================================================================================== */

USE [Inventory_Shipment];
GO

IF OBJECT_ID(N'masterdata.Ports', N'U') IS NULL
    THROW 50000, 'Script 112 requires script 24: apply it first.', 1;
GO

SET XACT_ABORT ON;
BEGIN TRANSACTION;

DECLARE @Pairs TABLE (OldCode NVARCHAR(20) NOT NULL, SeedCode NVARCHAR(20) NOT NULL);
INSERT INTO @Pairs (OldCode, SeedCode) VALUES (N'TZ-DAR', N'TZDAR'), (N'CD-LUB', N'CDLUB');

DECLARE @OldCode NVARCHAR(20), @SeedCode NVARCHAR(20), @OldId INT, @SeedId INT;
DECLARE pairs CURSOR LOCAL FAST_FORWARD FOR SELECT OldCode, SeedCode FROM @Pairs;
OPEN pairs;
FETCH NEXT FROM pairs INTO @OldCode, @SeedCode;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @OldId = (SELECT Id FROM masterdata.Ports WITH (UPDLOCK, HOLDLOCK) WHERE PortCode = @OldCode);
    SET @SeedId = (SELECT Id FROM masterdata.Ports WITH (UPDLOCK, HOLDLOCK) WHERE PortCode = @SeedCode);

    IF @OldId IS NOT NULL AND @SeedId IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM logistics.Containers WHERE @SeedId IN (PortOfLoadingId, PortOfDestinationId, FinalDestinationId))
           OR EXISTS (SELECT 1 FROM logistics.Movements WHERE @SeedId IN (FromPlaceId, ToPlaceId))
           OR EXISTS (SELECT 1 FROM logistics.ContainerEvents WHERE PortId = @SeedId)
           OR EXISTS (SELECT 1 FROM logistics.ShipmentStages WHERE @SeedId IN (FromPlaceId, ToPlaceId))
           OR EXISTS (SELECT 1 FROM inventory.ItemBivacPortCosts WHERE PortId = @SeedId)
            PRINT CONCAT('Script 112: ', @SeedCode, ' is in use: not merged with ', @OldCode, '.');
        ELSE
        BEGIN
            DELETE FROM masterdata.Ports WHERE Id = @SeedId;
            UPDATE masterdata.Ports SET PortCode = @SeedCode, UpdatedAtUtc = SYSUTCDATETIME() WHERE Id = @OldId;
            PRINT CONCAT('Script 112: ', @OldCode, ' is now ', @SeedCode, ' (the unused duplicate deleted).');
        END
    END

    FETCH NEXT FROM pairs INTO @OldCode, @SeedCode;
END
CLOSE pairs;
DEALLOCATE pairs;

COMMIT TRANSACTION;
GO

PRINT 'Script 112 applied: one port per place (TZ-DAR / CD-LUB take the codes TZDAR / CDLUB).';
GO
