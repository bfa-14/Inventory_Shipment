using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Configuration;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers.Configuration;

/// <summary>
/// Global settings. The list and the writes need the manage permission; the LOOKUP is open to any
/// signed-in user, because a screen such as the sales invoice reads the public settings to decide how
/// to behave.
/// </summary>
[ApiController]
[Route("api/settings")]
[Produces("application/json")]
public sealed class SettingsController : ControllerBase
{
    private readonly ISettingService _settings;

    public SettingsController(ISettingService settings)
    {
        _settings = settings;
    }

    [HttpGet]
    [HasPermission(Permissions.Configuration.SettingsManage)]
    [ProducesResponseType<IReadOnlyList<SettingDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<SettingDto>>> List(CancellationToken cancellationToken)
    {
        var result = await _settings.ListAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Only the settings marked public: key, type and value.</summary>
    [HttpGet("lookup")]
    [Authorize]
    [ProducesResponseType<IReadOnlyList<SettingLookupDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<SettingLookupDto>>> Lookup(CancellationToken cancellationToken)
    {
        var result = await _settings.LookupAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>400 VALIDATION when the value does not fit the setting's type or limits; 404 for an unknown key.</summary>
    [HttpPut("{key}")]
    [HasPermission(Permissions.Configuration.SettingsManage)]
    [ProducesResponseType<SettingDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<SettingDto>> Save(string key, [FromBody] SaveSettingRequest request, CancellationToken cancellationToken)
    {
        var result = await _settings.SaveAsync(key, request, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Back to the default: the administrator's choice is dropped.</summary>
    [HttpPost("{key}/reset")]
    [HasPermission(Permissions.Configuration.SettingsManage)]
    [ProducesResponseType<SettingDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<SettingDto>> Reset(string key, CancellationToken cancellationToken)
    {
        var result = await _settings.ResetAsync(key, User.GetUserId(), User.GetPermissions(), cancellationToken);
        return result.ToActionResult(this);
    }
}
