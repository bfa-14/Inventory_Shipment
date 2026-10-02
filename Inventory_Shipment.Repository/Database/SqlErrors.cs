using Inventory_Shipment.Repository.Exceptions;
using Microsoft.Data.SqlClient;

namespace Inventory_Shipment.Repository.Database;

/// <summary>
/// Error numbers raised with THROW by the stored procedures, and the translation from a
/// <see cref="SqlException"/> into a <see cref="BusinessRuleException"/> the service layer understands.
/// Each module owns a block: 50xxx security, 56xxx inventory, 51xxx-55xxx + 57xxx-60xxx master data,
/// 61xxx sales imports, 62xxx inventory documents, 64xxx sales documents, 65xxx-68xxx purchase
/// and shortage plans, 69xxx logistics (containers) and 70xxx logistics (movements, container charges,
/// attachments, movement types).
/// </summary>
public static class SqlErrors
{
    // ----- 50xxx: security -----
    public const int RoleNotFound = 50001;
    public const int SystemRolePermissions = 50002;
    public const int UserNotFound = 50003;
    public const int LastAdministrator = 50004;
    public const int SystemRoleDelete = 50005;
    public const int RoleStillAssigned = 50006;

    // ----- 51xxx: master data -----
    public const int Validation = 51000;
    public const int BranchDuplicateCode = 51001;
    public const int BranchMainExists = 51002;
    public const int BranchReferenced = 51003;
    public const int Concurrency = 51004;
    public const int BranchMainProtected = 51005;
    public const int BranchNotFound = 51006;

    // ----- 52xxx: master data - warehouses -----
    public const int WarehouseValidation = 52000;
    public const int WarehouseDuplicateCode = 52001;
    public const int WarehouseMainExists = 52002;
    public const int WarehouseReferenced = 52003;
    public const int WarehouseConcurrency = 52004;
    public const int WarehouseMainProtected = 52005;
    public const int WarehouseNotFound = 52006;
    public const int WarehouseBranchInactive = 52007;

    /// <summary>A warehouse moved under itself, or under one of its own descendants.</summary>
    public const int WarehouseCircular = 52008;

    // ----- 53xxx: master data - currencies and exchange rates -----
    public const int CurrencyValidation = 53000;
    public const int CurrencyDuplicateCode = 53001;
    public const int CurrencyBaseExists = 53002;
    public const int CurrencyReferenced = 53003;
    public const int CurrencyConcurrency = 53004;
    public const int CurrencyBaseProtected = 53005;
    public const int CurrencyNotFound = 53006;
    public const int ExchangeRateDuplicate = 53007;
    public const int CurrencyInactive = 53008;

    // ----- 54xxx: master data - item families (self-referencing tree) -----
    public const int ItemFamilyValidation = 54000;
    public const int ItemFamilyDuplicateCode = 54001;
    public const int ItemFamilyDuplicateName = 54002;
    public const int ItemFamilyReferenced = 54003;
    public const int ItemFamilyConcurrency = 54004;
    public const int ItemFamilyHasChildren = 54005;
    public const int ItemFamilyNotFound = 54006;
    public const int ItemFamilyCircularHierarchy = 54007;
    public const int ItemFamilyParentInactive = 54008;

    // ----- 55xxx: master data - brands -----
    public const int BrandValidation = 55000;
    public const int BrandDuplicateCode = 55001;
    public const int BrandReferenced = 55003;
    public const int BrandConcurrency = 55004;
    public const int BrandNotFound = 55006;

    // ----- 56xxx: inventory - item definition (items, units, files) -----
    public const int ItemValidation = 56000;
    public const int ItemDuplicateCode = 56001;
    public const int ItemDuplicateBarcode = 56002;
    public const int ItemReferenced = 56003;
    public const int ItemConcurrency = 56004;
    public const int ItemBaseUnitRule = 56005;
    public const int ItemNotFound = 56006;
    public const int ItemDuplicateSku = 56007;
    public const int ItemMasterInactive = 56008;

    // ----- 57xxx: master data - unit types -----
    public const int UnitTypeValidation = 57000;
    public const int UnitTypeDuplicateName = 57001;
    public const int UnitTypeReferenced = 57003;
    public const int UnitTypeConcurrency = 57004;
    public const int UnitTypeNotFound = 57006;

    // ----- 58xxx: master data - price lists -----
    public const int PriceListValidation = 58000;
    public const int PriceListDuplicateCode = 58001;
    public const int PriceListReferenced = 58003;
    public const int PriceListConcurrency = 58004;
    public const int PriceListNotFound = 58006;
    public const int PriceListCurrencyInactive = 58008;
    public const int PriceListCurrencyLocked = 58009;

    // ----- 60xxx: master data - parties (suppliers / clients / salesmen / employees) -----
    public const int PartyValidation = 60000;
    public const int PartyDuplicateCode = 60001;
    public const int PartyUserAlreadyLinked = 60002;
    public const int PartyReferenced = 60003;
    public const int PartyConcurrency = 60004;
    public const int PartyTypeInUse = 60005;
    public const int PartyNotFound = 60006;
    public const int PartyMasterInactive = 60008;

    // ----- 61xxx: sales - invoice import -----
    public const int InvoiceImportValidation = 61000;

    /// <summary>Branch, default warehouse or price list missing or inactive, or the warehouse is not in the branch.</summary>
    public const int InvoiceImportMasterInactive = 61008;

    // ----- 62xxx: inventory - stock documents and the ledger -----
    public const int StockDocumentValidation = 62000;
    public const int StockDocumentConcurrency = 62004;

    /// <summary>The document is not a draft, so it cannot be edited or deleted.</summary>
    public const int StockDocumentNotDraft = 62005;

    public const int StockDocumentNotFound = 62006;

    /// <summary>Posting or cancelling would take stock below zero. The message names the item, the warehouse and both figures.</summary>
    public const int StockDocumentInsufficientStock = 62007;

    public const int StockDocumentMasterInactive = 62008;
    public const int StockDocumentNoLines = 62009;

    /// <summary>The lifecycle forbids the move — posting something already posted, cancelling a draft.</summary>
    public const int StockDocumentInvalidStatus = 62010;

    // ----- 64xxx: sales - invoices (the Sales document family) -----
    public const int SalesDocumentValidation = 64000;
    public const int SalesDocumentConcurrency = 64004;
    public const int SalesDocumentNotDraft = 64005;
    public const int SalesDocumentNotFound = 64006;
    public const int SalesDocumentInsufficientStock = 64007;

    /// <summary>The invoice sells more than a warehouse holds, the policy allows it, and the caller has not confirmed yet.</summary>
    public const int SalesDocumentOutOfStockConfirm = 64016;

    /// <summary>Branch, warehouse, client, salesman or price list missing / inactive — or no exchange rate for the date.</summary>
    public const int SalesDocumentMasterInactive = 64008;

    public const int SalesDocumentNoLines = 64009;
    public const int SalesDocumentInvalidStatus = 64010;

    /// <summary>A line whose item unit has no price in the chosen list, and the caller may not override. The message names the line.</summary>
    public const int SalesDocumentNoPrice = 64011;

    // ----- 65xxx: purchase - orders, invoices and returns (the Purchase document family) -----
    public const int PurchaseDocumentValidation = 65000;
    public const int PurchaseDocumentConcurrency = 65004;
    public const int PurchaseDocumentNotDraft = 65005;
    public const int PurchaseDocumentNotFound = 65006;
    public const int PurchaseDocumentInsufficientStock = 65007;
    public const int PurchaseDocumentMasterInactive = 65008;
    public const int PurchaseDocumentNoLines = 65009;
    public const int PurchaseDocumentInvalidStatus = 65010;

    /// <summary>The chain is broken: wrong source kind, source not open, more than remains, or a posted child in the way.</summary>
    public const int PurchaseDocumentSourceInvalid = 65011;

    /// <summary>An imported invoice (from containers) is posted without the exporter reference.</summary>
    public const int PurchaseExporterReferenceRequired = 65018;

    /// <summary>An invoice line and its container line disagree: missing, another order, or more than is loaded.</summary>
    public const int PurchaseContainerLineInvalid = 65019;

    /// <summary>Charges typed on an imported invoice: an import's charges are entered on its containers.</summary>
    public const int PurchaseChargesOnContainer = 65020;

    /// <summary>The order is shipped in containers: invoiced from them, not from the order; not cancelled or closed while loaded.</summary>
    public const int PurchaseOrderInContainers = 65021;

    // ----- 65026-65028: an invoice and its containers (script 43) -----

    /// <summary>"Shipped in containers" switched off while lines are linked, or the goods would be received twice.</summary>
    public const int PurchaseReceiptModeRefused = 65026;

    /// <summary>The container has started moving (or is cancelled): it can no longer be linked to or unlinked from an invoice.</summary>
    public const int PurchaseContainerMoving = 65027;

    /// <summary>The invoice cannot be linked: not from an order, received on posting, landed cost adjustment, returns.</summary>
    public const int PurchaseInvoiceNotLinkable = 65028;

    // ----- 65029: one item per supplier invoice (script 45) -----

    /// <summary>A supplier invoice holds one item: saving or posting one with lines of several items is refused.</summary>
    public const int PurchaseInvoiceOneItem = 65029;

    // ----- 65013-65017, 65022-65024: purchase order approval (scripts 26 and 42) -----

    /// <summary>A purchase order that needs approval was posted directly: send it for approval.</summary>
    public const int PurchaseOrderApprovalRequired = 65013;

    /// <summary>An emailed approval link cannot be used; the message says why (approved by, rejected, withdrawn, expired, used).</summary>
    public const int ApprovalLinkNotUsable = 65014;

    /// <summary>Nobody can approve the order: no approver is ticked in Settings > Purchase approval.</summary>
    public const int ApprovalNoApprover = 65015;

    /// <summary>The supplier has no email address while the approved order is to be emailed to it.</summary>
    public const int ApprovalSupplierWithoutEmail = 65016;

    /// <summary>The user is not (or no longer) an approver of this order, in the app or by email.</summary>
    public const int ApprovalNotApprover = 65017;

    /// <summary>The order does not need approval (settings, or under the limit): post it.</summary>
    public const int ApprovalNotNeeded = 65022;

    /// <summary>Self-approval is off and the user created or sent the order.</summary>
    public const int ApprovalSelfApproval = 65023;

    /// <summary>Settings > Purchase approval refused (limits, approvers without an address, nobody ticked...).</summary>
    public const int ApprovalSettingsValidation = 65024;

    /// <summary>Settings > Email refused (script 42): server and sender needed to send, port, security, addresses, link address.</summary>
    public const int EmailSettingsValidation = 65025;

    // ----- 66xxx: inventory - shortage planning documents -----
    public const int ShortageDocumentValidation = 66000;
    public const int ShortageDocumentConcurrency = 66004;
    public const int ShortageDocumentNotDraft = 66005;
    public const int ShortageDocumentNotFound = 66006;
    public const int ShortageDocumentNoLines = 66009;
    public const int ShortageDocumentInvalidStatus = 66010;

    /// <summary>A purchase order was asked of a posted plan on which no line has a required quantity above zero.</summary>
    public const int ShortageDocumentNothingToOrder = 66011;

    /// <summary>A purchase charge could not be allocated: no weight, no volume, a zero basis, or manual amounts that do not add up.</summary>
    public const int PurchaseChargeAllocation = 65012;

    // ----- 67xxx: purchase - landed cost adjustments (charges arriving after receipt) -----
    public const int LandedCostValidation = 67000;
    public const int LandedCostConcurrency = 67004;
    public const int LandedCostNotDraft = 67005;
    public const int LandedCostNotFound = 67006;
    public const int LandedCostInvalidStatus = 67010;

    /// <summary>The source invoice is missing, not a purchase invoice, not posted, or still carries a posted adjustment.</summary>
    public const int LandedCostSourceInvalid = 67011;

    /// <summary>A landed cost adjustment on an imported invoice: its late charges go on the containers.</summary>
    public const int LandedCostImportedInvoice = 67012;

    // ----- 68xxx: purchase - charge types (US-MD-008) -----
    public const int ChargeTypeValidation = 68000;
    public const int ChargeTypeDuplicateCode = 68001;
    public const int ChargeTypeDuplicateName = 68002;
    public const int ChargeTypeConcurrency = 68004;
    public const int ChargeTypeInUse = 68005;
    public const int ChargeTypeNotFound = 68006;

    // ----- 69xxx: logistics - containers and their master data (container types, ports, attachment types) -----
    public const int ContainerValidation = 69000;
    public const int ContainerConcurrency = 69004;

    /// <summary>Offloaded, closed or cancelled containers (and non-draft ones, for a delete) cannot be changed.</summary>
    public const int ContainerNotEditable = 69005;

    public const int ContainerNotFound = 69006;

    /// <summary>More units allocated than the container holds, and the caller did not confirm the override.</summary>
    public const int ContainerOverCapacity = 69007;

    /// <summary>A line takes more of an invoice line than remains on it. The message names both lines and figures.</summary>
    public const int ContainerAllocationExceedsInvoice = 69008;

    public const int ContainerNoLines = 69009;
    public const int ContainerInvalidStatus = 69010;
    public const int ContainerAlreadyOffloaded = 69011;

    /// <summary>
    /// An invoice and a container disagree: the invoice is cancelled or already received, or — raised by
    /// the purchase procedures — it cannot be edited, cancelled or deleted while a container carries it.
    /// </summary>
    public const int ContainerInvoiceInUse = 69012;

    /// <summary>Another open container has the box number, or a master data code already exists.</summary>
    public const int ContainerDuplicate = 69013;

    /// <summary>A container type, port or attachment type that containers use cannot be deleted.</summary>
    public const int LogisticsMasterInUse = 69014;

    /// <summary>Reversing an offload would take an item below zero: the goods were already sold or moved.</summary>
    public const int ContainerInsufficientStock = 69015;

    /// <summary>The offload needs every container line fully covered by POSTED invoices.</summary>
    public const int ContainerNotFullyInvoiced = 69016;

    /// <summary>A container line is invoiced: it cannot be removed, nor loaded below what is invoiced.</summary>
    public const int ContainerLineInvoiced = 69017;

    /// <summary>A charge was posted after the offload (a cost adjustment exists): the offload cannot be reversed.</summary>
    public const int ContainerCostAdjusted = 69018;

    // ----- 70xxx: logistics - movements, container charges, attachments, movement types -----
    public const int LogisticsValidation = 70000;
    public const int LogisticsDuplicate = 70001;
    public const int LogisticsConcurrency = 70004;
    public const int LogisticsNotEditable = 70005;
    public const int LogisticsNotFound = 70006;
    public const int LogisticsInvalidStatus = 70010;

    /// <summary>The container travels with another movement in progress, or a movement still holds it.</summary>
    public const int ContainerBusy = 70012;

    /// <summary>A charge cannot be allocated: no weight, no volume, a zero basis, or manual shares that do not add up.</summary>
    public const int ChargeAllocationDataMissing = 70013;

    public const int LogisticsInUse = 70014;

    // ----- 71xxx: customer receipts - payment methods, cash / bank accounts, receipts -----
    public const int ReceiptValidation = 71000;
    public const int ReceiptConcurrency = 71004;
    public const int ReceiptNotEditable = 71005;
    public const int ReceiptNotFound = 71006;

    /// <summary>The payment lines or the allocations do not add up to the receipt amount.</summary>
    public const int ReceiptNotBalanced = 71008;

    /// <summary>An allocation is more than its invoice still owes.</summary>
    public const int ReceiptAllocationExceeds = 71009;

    /// <summary>The receipt is not in the status the action needs (post a draft, reverse a posted one...).</summary>
    public const int ReceiptInvalidStatus = 71010;

    /// <summary>More allocated than the receipt has left unapplied.</summary>
    public const int ReceiptUnappliedExceeded = 71011;

    /// <summary>A Free Receipt that has since paid invoices cannot be reversed until those allocations are removed.</summary>
    public const int ReceiptHasAllocations = 71012;

    /// <summary>A payment method or account code that already exists.</summary>
    public const int ReceiptDuplicateCode = 71013;

    /// <summary>A payment method or cash / bank account that receipts use cannot be deleted.</summary>
    public const int ReceiptMasterInUse = 71014;

    /// <summary>A receipt created by a Cash invoice cannot be reversed on its own.</summary>
    public const int ReceiptAutomatic = 71015;

    // ----- 72xxx: global settings -----
    public const int SettingValidation = 72000;
    public const int SettingNotFound = 72006;

    private const int FirstBusinessRule = 50000;

    // The ceiling moves with the newest block (71xxx is receipts): a ceiling left behind
    // its own module is how a deliberate THROW reaches the API as an unhandled database failure.
    private const int LastBusinessRule = 72999;

    private const int FirstSecurityRule = 50001;
    private const int LastSecurityRule = 50999;

    /// <summary>True when the exception is a deliberate business-rule THROW rather than a database failure.</summary>
    public static bool IsBusinessRule(SqlException exception)
        => exception.Number is >= FirstBusinessRule and <= LastBusinessRule;

    /// <summary>
    /// Wraps a business-rule SqlException, keeping the message written in the procedure. Numbers in the
    /// security block become a <see cref="SecurityRuleException"/> so existing catch blocks still match.
    /// </summary>
    public static BusinessRuleException Wrap(SqlException exception)
        => exception.Number is >= FirstSecurityRule and <= LastSecurityRule
            ? new SecurityRuleException(exception.Number, exception.Message, exception)
            : new BusinessRuleException(exception.Number, exception.Message, exception);

    /// <summary>Wraps a security-procedure SqlException (50001-50999).</summary>
    public static SecurityRuleException ToSecurityRuleException(SqlException exception)
        => new(exception.Number, exception.Message, exception);
}
