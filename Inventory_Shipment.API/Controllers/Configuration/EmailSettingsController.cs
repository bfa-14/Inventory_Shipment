using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Messaging;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Configuration;

/// <summary>
/// Settings > Email: the mail server, the sender, the address of the application used in the links, and a
/// test. The password is accepted, never returned.
/// </summary>
[ApiController]
[Route("api/settings/email")]
[Produces("application/json")]
[HasPermission(Permissions.Configuration.EmailSettingsManage)]
public sealed class EmailSettingsController : ControllerBase
{
    private readonly IEmailSettingsService _settings;

    public EmailSettingsController(IEmailSettingsService settings)
    {
        _settings = settings;
    }

    [HttpGet]
    [ProducesResponseType<EmailSettingsDto>(StatusCodes.Status200OK)]
    public async Task<ActionResult<EmailSettingsDto>> Get(CancellationToken cancellationToken)
    {
        var result = await _settings.GetAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Password null or "" keeps the saved one; removePassword removes it. 400 VALIDATION with the
    /// procedure's message; 409 CONCURRENCY when somebody saved meanwhile.
    /// </summary>
    [HttpPut]
    [ProducesResponseType<EmailSettingsDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<EmailSettingsDto>> Save([FromBody] SaveEmailSettingsRequest request, CancellationToken cancellationToken)
    {
        var result = await _settings.SaveAsync(request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>
    /// Sends one email at once with the values given (or the saved settings) and records the result. A
    /// refused or unreachable server is an answer (ok false, a readable error), not an HTTP error.
    /// </summary>
    [HttpPost("test")]
    [ProducesResponseType<EmailTestResultDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    public async Task<ActionResult<EmailTestResultDto>> Test([FromBody] TestEmailSettingsRequest request, CancellationToken cancellationToken)
    {
        var result = await _settings.TestAsync(request, User.GetUserId(), cancellationToken);
        return result.ToActionResult(this);
    }
}
