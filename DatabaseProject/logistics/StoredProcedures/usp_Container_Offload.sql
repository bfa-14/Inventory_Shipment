/* ================================================================== 7. The container Offload stays retired */

-- Re-created (72) from the body of script 65, unchanged: a refusal. Script 70 re-created the old offload (the body of
-- script 27 + "the offloading warehouse must be a leaf"); containers are received with a goods receipt
-- (purchase.usp_GoodsReceipt_CreateForContainer, then _Post), whose "Receive into" now follows that rule (sections 8
-- and 9). The parameters stay, so an old caller gets the reason rather than an error about the call.
CREATE   PROCEDURE logistics.usp_Container_Offload
    @Id            INT,
    @Lines         logistics.tvp_ContainerReceipt READONLY,   -- (65) ignored
    @OffloadedDate DATE      = NULL,                          -- (65) ignored
    @WarehouseId   INT       = NULL,                          -- (65) ignored
    @RowVersion    BINARY(8) = NULL,                          -- (65) ignored
    @UserId        INT       = NULL                           -- (65) ignored
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Msg NVARCHAR(200) = N'Containers are received with a goods receipt now. Use Receive goods' + NCHAR(8230) + N' on the container.';
    THROW 69010, @Msg, 1;
END

GO

