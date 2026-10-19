/* ==================================================================================================
   70: Document lines take a warehouse at the bottom of the tree, of any branch
   --------------------------------------------------------------------------------------------------
   Every detail line that moves stock (sales invoices and returns, purchase orders, invoices and
   returns, Inventory In and Out, and the Excel imports of these) names a warehouse:
     - of ANY branch: the header's branch numbers the document, it does not limit its lines
       (already so for sales and purchases; script 69 for Inventory In / Out; here for the import's
       default warehouse);
     - at the BOTTOM of the warehouse tree: a warehouse with warehouses under it is a group, not a
       place that holds stock, so no line may take or put stock there.

     masterdata.fn_Warehouse_IsLeaf                  new: 1 when no warehouse stands under it
     sales.usp_SalesDocument_ValidateInput           (save)  refuses a parent warehouse on a line
     purchase.usp_PurchaseDocument_ValidateInput     (save)  the same
     inventory.usp_StockDocument_ValidateInput       (save)  the same
     sales.usp_SalesDocument_Post                    refuses a draft saved before with one
     purchase.usp_PurchaseDocument_Post              the same
     inventory.usp_StockDocument_Post                the same
     sales.usp_InvoiceImport_Validate                the default warehouse may be of any branch but
                                                     must be a leaf; a row naming a parent is an Error
     logistics.usp_Container_Offload                 the offloading warehouse must be a leaf (it stays
                                                     in the container's branch, a rule of its own)

   Each procedure is re-created from its current body with only these changes.
   ================================================================================================== */

CREATE   FUNCTION masterdata.fn_Warehouse_IsLeaf (@WarehouseId INT)
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN EXISTS (SELECT 1 FROM masterdata.Warehouses WHERE ParentId = @WarehouseId) THEN 0 ELSE 1 END;
END

GO

