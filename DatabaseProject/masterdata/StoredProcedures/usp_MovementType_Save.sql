CREATE   PROCEDURE masterdata.usp_MovementType_Save
    @Id         INT           = NULL,
    @TypeCode   NVARCHAR(10),
    @TypeName   NVARCHAR(100),
    @Stage      NVARCHAR(10),
    @SortOrder  INT           = 0,
    @IsActive   BIT           = 1,
    @RowVersion BINARY(8)     = NULL,
    @UserId     INT           = NULL,
    @NewId      INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @TypeCode = UPPER(NULLIF(LTRIM(RTRIM(@TypeCode)), N''));
    SET @TypeName = NULLIF(LTRIM(RTRIM(@TypeName)), N'');
    SET @Stage = NULLIF(LTRIM(RTRIM(@Stage)), N'');
    IF @TypeCode IS NULL THROW 70000, 'Movement type code is required.', 1;
    IF @TypeName IS NULL THROW 70000, 'Movement type name is required.', 1;
    IF @Stage IS NULL OR @Stage NOT IN (N'Origin', N'Sea', N'Transit', N'Port', N'Border', N'Customs', N'Delivery')
        THROW 70000, 'Stage must be Origin, Sea, Transit, Port, Border, Customs or Delivery.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE TypeCode = @TypeCode AND (@Id IS NULL OR Id <> @Id))
        THROW 70001, 'This movement type code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.MovementTypes (TypeCode, TypeName, Stage, SortOrder, IsActive, CreatedBy)
        VALUES (@TypeCode, @TypeName, @Stage, ISNULL(@SortOrder, 0), ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id) THROW 70006, 'Movement type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 70004, 'This movement type was modified by another user. Reload the page and try again.', 1;
        -- the stage drives the container status: it cannot change once the type is used
        IF EXISTS (SELECT 1 FROM masterdata.MovementTypes WHERE Id = @Id AND Stage <> @Stage)
           AND EXISTS (SELECT 1 FROM logistics.Movements WHERE MovementTypeId = @Id)
            THROW 70014, 'This movement type is used by movements: its stage can no longer change.', 1;
        UPDATE masterdata.MovementTypes
        SET TypeCode = @TypeCode, TypeName = @TypeName, Stage = @Stage, SortOrder = ISNULL(@SortOrder, 0),
            IsActive = ISNULL(@IsActive, 1), UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END

GO

