/* ================================================================== 1. logistics.usp_Container_SetRef */

CREATE   PROCEDURE logistics.usp_Container_SetRef
    @Id           INT,
    @ContainerRef NVARCHAR(100),          -- wider than the column, so a ref that is too long is said, not cut
    @RowVersion   BINARY(8) = NULL,
    @UserId       INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @New NVARCHAR(100) = UPPER(LTRIM(RTRIM(ISNULL(@ContainerRef, N''))));
    DECLARE @Msg NVARCHAR(400);

    IF @New = N'' THROW 69000, 'Type the container ref.', 1;
    IF LEN(@New) > 30 THROW 69000, 'A container ref has at most 30 characters.', 1;
    IF @New LIKE N'%[,;/\]%' OR CHARINDEX(NCHAR(9), @New) > 0 OR CHARINDEX(NCHAR(10), @New) > 0 OR CHARINDEX(NCHAR(13), @New) > 0
        THROW 69000, 'A container ref cannot hold a comma, a semicolon, a slash or a line break.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @Old NVARCHAR(30), @Status TINYINT;
        SELECT @Old = ContainerRef, @Status = Status FROM logistics.Containers WITH (UPDLOCK, HOLDLOCK) WHERE Id = @Id;
        IF @Old IS NULL THROW 69006, 'Container not found.', 1;
        IF @Status = 8 THROW 69010, 'This container is cancelled: its ref can no longer change.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM logistics.Containers WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 69004, 'This container was modified by another user. Reload the page and try again.', 1;
        IF @New = @Old
        BEGIN
            SET @Msg = N'The container ref is already ' + @Old + N'.';
            THROW 69000, @Msg, 1;
        END

        -- Another container has it (whatever its status: the ref is unique among all of them).
        SELECT TOP (1) @Msg = N'Container ref ' + @New + N' is already used by another container'
                            + CASE o.Status WHEN 8 THEN N' (cancelled)' WHEN 1 THEN N' (a draft)' ELSE N'' END
                            + N'. Choose another ref.'
        FROM logistics.Containers o WHERE o.ContainerRef = @New AND o.Id <> @Id;
        IF @Msg IS NOT NULL THROW 69013, @Msg, 1;

        -- A NUMBER THE COUNTER HAS NOT REACHED YET: {prefix}{year}-{digits} (or {prefix}{digits} without the year) that
        -- inventory.usp_DocumentType_NextNumber would give one day. Taken by hand now, that day's container - and every
        -- one after it - would be refused as a duplicate. The type's row is locked as NextNumber locks it, so a
        -- container being numbered at this instant is counted.
        DECLARE @Prefix NVARCHAR(10), @YearIn BIT, @Next INT, @NextYear INT, @PerBranch BIT;
        SELECT @Prefix = NumberPrefix, @YearIn = YearInNumber, @Next = NextNumber, @NextYear = NextNumberYear, @PerBranch = NumberPerBranch
        FROM inventory.DocumentTypes WITH (UPDLOCK, ROWLOCK) WHERE Code = N'CNT';

        IF @Prefix IS NOT NULL AND ISNULL(@PerBranch, 0) = 0 AND LEFT(@New, LEN(@Prefix)) = UPPER(@Prefix)
        BEGIN
            DECLARE @Rest NVARCHAR(100) = SUBSTRING(@New, LEN(@Prefix) + 1, 100), @RefYear INT = NULL, @RefNo BIGINT = NULL;
            DECLARE @ThisYear INT = YEAR(SYSUTCDATETIME());
            IF @YearIn = 1 AND @Rest LIKE N'[0-9][0-9][0-9][0-9]-[0-9]%' AND SUBSTRING(@Rest, 6, 100) NOT LIKE N'%[^0-9]%' AND LEN(@Rest) <= 23
                SELECT @RefYear = CAST(LEFT(@Rest, 4) AS INT), @RefNo = CAST(SUBSTRING(@Rest, 6, 100) AS BIGINT);
            ELSE IF ISNULL(@YearIn, 0) = 0 AND @Rest LIKE N'[0-9]%' AND @Rest NOT LIKE N'%[^0-9]%' AND LEN(@Rest) <= 18
                SELECT @RefYear = 0, @RefNo = CAST(@Rest AS BIGINT);

            IF @RefNo IS NOT NULL
               AND (   (@YearIn = 1 AND @RefYear > @ThisYear)                                              -- a year still to come
                    OR (@YearIn = 1 AND @RefYear = @ThisYear AND ISNULL(@NextYear, 0) <> @ThisYear)       -- this year, none given yet
                    OR (@YearIn = 1 AND @RefYear = @ThisYear AND @NextYear = @ThisYear AND @RefNo >= @Next)
                    OR (ISNULL(@YearIn, 0) = 0 AND @RefNo >= ISNULL(@Next, 1)))
            BEGIN
                SET @Msg = @New + N' is a number the system has not given yet: a new container will take it one day. Choose another ref'
                         + N' (for example ' + LEFT(@New, 26) + N'-A).';
                THROW 69000, @Msg, 1;
            END
        END

        UPDATE logistics.Containers
        SET ContainerRef = @New, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        -- The stock rows of an offload made before goods receipts carry the ref ({ref} or {ref}/N): renamed with it, so
        -- the item's statement and Cancel Offload still find them. No row is added: the ledger's quantities do not move.
        UPDATE m
        SET DocumentNumber = @New + SUBSTRING(m.DocumentNumber, LEN(@Old) + 1, 30)
        FROM inventory.StockMovements m
        WHERE m.DocumentFamily = N'Purchase' AND m.DocumentTypeCode = N'CNT' AND m.DocumentId = @Id
          AND (m.DocumentNumber = @Old OR m.DocumentNumber LIKE REPLACE(REPLACE(REPLACE(@Old, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'/%');

        INSERT INTO logistics.ContainerAudit (ContainerId, Action, Details, UserId)
        VALUES (@Id, N'Updated', N'Ref changed: ' + @Old + N' -> ' + @New, @UserId);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        IF ERROR_NUMBER() IN (2601, 2627)
            THROW 69013, 'This container ref was just given to another container. Choose another ref.', 1;
        THROW;
    END CATCH
END

GO

