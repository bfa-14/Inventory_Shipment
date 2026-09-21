CREATE   PROCEDURE inventory.usp_Item_SetPurchasing
    @Id                INT,
    @DefaultSupplierId INT           = NULL,
    @LeadTimeDays      INT           = NULL,
    @UserId            INT           = NULL,
    @PcPerContainer    INT           = NULL,
    @WeightKg          DECIMAL(18,3) = NULL,
    @VolumeCbm         DECIMAL(18,4) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inventory.Items WHERE Id = @Id) THROW 56000, 'Item not found.', 1;
    IF @DefaultSupplierId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @DefaultSupplierId AND IsSupplier = 1 AND IsActive = 1)
        THROW 56000, 'Default supplier not found, inactive, or not flagged as a supplier.', 1;
    IF @LeadTimeDays IS NOT NULL AND @LeadTimeDays < 0 THROW 56000, 'Lead time cannot be negative.', 1;
    IF @PcPerContainer IS NOT NULL AND @PcPerContainer <= 0 THROW 56000, 'PC per container must be greater than zero.', 1;
    IF @WeightKg IS NOT NULL AND @WeightKg < 0 THROW 56000, 'Weight cannot be negative.', 1;
    IF @VolumeCbm IS NOT NULL AND @VolumeCbm < 0 THROW 56000, 'Volume cannot be negative.', 1;

    UPDATE inventory.Items
    SET DefaultSupplierId = @DefaultSupplierId, LeadTimeDays = @LeadTimeDays, PcPerContainer = @PcPerContainer,
        WeightKg = @WeightKg, VolumeCbm = @VolumeCbm, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
    WHERE Id = @Id;
END