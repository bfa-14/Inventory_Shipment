/* ================================================================== 3. The column of a container on the board */

-- One row: the column of the Shipments board a container stands in, from what the caller already read of it - its
-- status, its open goods receipt (fn_Container_ReceivedBy), the leg in progress carrying it (its stage, type code and the
-- kinds of its From and To) and its last completed leg (stage, kind of its To; NULL = it never moved). The first that
-- applies (see the header): a leg in progress decides first, as in fn_Container_NextStepKind. NULL for a cancelled
-- container: it is never on the board. PhaseOrder is the column's place, left to right.
-- A container FOLLOWED BY TYPED DATES (no leg started or completed, business-context 3.5 item 11) stands where its status
-- says: only the dates typed on its header raise it above Confirmed (usp_Container_RefreshStatus), so 3 In Transit is at
-- sea, 4 At Port at its port, 5 Cleared at border / customs.
CREATE   FUNCTION logistics.fn_Container_BoardPhase
(
    @Status             TINYINT,
    @GoodsReceiptStatus TINYINT,
    @ActiveStage        NVARCHAR(10),
    @ActiveTypeCode     NVARCHAR(10),
    @ActiveFromKind     NVARCHAR(10),
    @ActiveToKind       NVARCHAR(10),
    @LastStage          NVARCHAR(10),
    @LastToKind         NVARCHAR(10)
)
RETURNS TABLE
AS
RETURN
SELECT p.Phase,
       PhaseOrder = CASE p.Phase WHEN N'AtSupplier' THEN 1 WHEN N'AtSea' THEN 2 WHEN N'AtPort' THEN 3 WHEN N'OnTheRoad' THEN 4
                                 WHEN N'AtBorderCustoms' THEN 5 WHEN N'Delivered' THEN 6 WHEN N'Received' THEN 7 END
FROM (SELECT Phase = CAST(CASE
          WHEN @Status IS NULL OR @Status = 8 THEN NULL
          WHEN @Status IN (6, 7) THEN N'Received'
          WHEN @ActiveStage = N'Origin' THEN N'AtSupplier'
          -- a vessel leg: sea freight, or a transshipment between two sea ports (feeder vessel, not inland transport)
          WHEN @ActiveStage = N'Sea'
               OR (@ActiveStage = N'Transit' AND ISNULL(@ActiveTypeCode, N'') <> N'INLAND'
                   AND @ActiveFromKind = N'Sea' AND @ActiveToKind = N'Sea') THEN N'AtSea'
          WHEN @ActiveStage = N'Port' THEN N'AtPort'
          WHEN @ActiveStage = N'Customs' THEN N'AtBorderCustoms'
          WHEN @ActiveStage IS NOT NULL THEN N'OnTheRoad'                 -- inland transport, a border crossing, a delivery
          WHEN @GoodsReceiptStatus = 1 THEN N'Delivered'                  -- a draft goods receipt waits
          -- followed by typed dates: never started a leg, the status its typed dates gave it
          WHEN @LastStage IS NULL AND @Status = 3 THEN N'AtSea'
          WHEN @LastStage IS NULL AND @Status = 4 THEN N'AtPort'
          WHEN @LastStage IS NULL AND @Status = 5 THEN N'AtBorderCustoms'
          WHEN @LastStage IS NULL THEN N'AtSupplier'                      -- never started a leg
          WHEN @LastStage = N'Delivery' THEN N'Delivered'
          WHEN @LastToKind = N'Sea' THEN N'AtPort'
          ELSE N'AtBorderCustoms' END AS NVARCHAR(16))) p;

GO

