/* ================================================================== 3. Charge type procedures */

CREATE   PROCEDURE purchase.usp_ChargeType_Lookup
    @ActiveOnly BIT = 1, @IncludeId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT Id, ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, IsActive,
           IsDeduction                                                     -- (102)
    FROM purchase.ChargeTypes
    WHERE @ActiveOnly = 0 OR IsActive = 1 OR Id = @IncludeId
    ORDER BY ChargeName;
END

GO

