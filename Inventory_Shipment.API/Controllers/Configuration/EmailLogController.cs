using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Configuration;

/// <summary>Settings > Email log: every email the application queued, its status, its HTML; retry and a test.</summary>
[ApiController]
[Route("api/settings/emails")]
[Produces("application/json")]
[HasPermission(Permissions.Configuration.EmailsView)]
public sealed class EmailLogController : ControllerBase
{
    private readonly IEmailLogService _emails;

    public EmailLogController(IEmailLogService emails)
    {
        _emails = emails;
    }

    /// <summary>Newest first. Status: Pending | Sent | Failed.</summary>
    [HttpGet]
    [ProducesResponseType<PagedResult<EmailListDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<PagedResult<EmailListDto>>> Search([FromQuery] EmailQuery query, CancellationToken cancellationToken)
    {
        var result = await _emails.SearchAsync(query, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>One email with its HTML (the attachment is named, not sent).</summary>
    [HttpGet("{id:long}")]
    [ProducesResponseType<EmailDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<EmailDto>> Get(long id, CancellationToken cancellationToken)
    {
        var result = await _emails.GetAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpPost("{id:long}/retry")]
    [ProducesResponseType<EmailDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<EmailDto>> Retry(long id, CancellationToken cancellationToken)
    {
        var result = await _emails.RetryAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Queues a short test email to the signed-in user's address; 400 when the user has none.</summary>
    [HttpPost("test")]
    [ProducesResponseType<EmailDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<EmailDto>> QueueTest(CancellationToken cancellationToken)
    {
        var result = await _emails.QueueTestAsync(User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }
}
