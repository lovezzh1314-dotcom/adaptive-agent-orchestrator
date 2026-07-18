[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
$examplePath = Join-Path $skillRoot 'references\example-plan.json'
$script:assertionCount = 0
$script:invalidPlanCount = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'adaptive-agent-orchestrator-' + [guid]::NewGuid().ToString('N')
)

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )
    $script:assertionCount++
    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function Assert-InvalidPlan {
    param(
        [hashtable] $Plan,
        [string] $Name,
        [string] $ExpectedMessage
    )
    $path = Join-Path $testRoot "$Name.json"
    $Plan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path
    $caught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
            -PlanPath $path -WorkspaceRoot $skillRoot | Out-Null
    }
    catch {
        $caught = $true
        Assert-True ($_.Exception.Message -like "*$ExpectedMessage*") (
            "Invalid plan '$Name' failed for the wrong reason: $($_.Exception.Message)"
        )
    }
    Assert-True $caught "Invalid plan '$Name' unexpectedly passed."
    $script:invalidPlanCount++
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot

    $valid = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
        -PlanPath $examplePath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $valid.valid 'Example plan should be valid.'
    Assert-True ($valid.agent_node_count -eq 2) 'Example should contain two agent nodes.'
    $activationPreview = & (
        Join-Path $scriptRoot 'New-RoleActivationPreview.ps1'
    ) -PlanPath $examplePath -NodeId 'draft'
    foreach ($requiredPreviewLabel in @(
        'Role:', 'Mission:', 'Identity:', 'Why a Worker is needed:', 'Concrete task:',
        'Responsibilities:', 'Non-goals:', 'Inputs and context scope:',
        'Excluded context:', 'Topology/session:',
        'Deliverables:', 'Evidence rules:', 'Permissions and write scope:',
        'Dependencies:', 'If omitted:', 'Authorization basis:',
        'Authorization evidence:'
    )) {
        Assert-True ($activationPreview -like "*$requiredPreviewLabel*") (
            "Role activation preview should include '$requiredPreviewLabel'."
        )
    }
    Assert-True ($activationPreview -like '*scoped-write: artifacts/draft*') (
        'Role activation preview should expose the exact write scope.'
    )
    Assert-True ($activationPreview -like '*background-thread / fresh*') (
        'Role activation preview should expose topology and session policy.'
    )
    Assert-True ($activationPreview -like '*Prior reviewer reasoning*') (
        'Role activation preview should expose excluded context.'
    )
    Assert-True ($activationPreview -match 'Architecture Owner \[architecture-owner\]') (
        'Role activation preview should render the selected role ID exactly.'
    )

    $roleCatalog = Get-Content -LiteralPath (
        Join-Path $skillRoot 'references/role-pack-catalog.json'
    ) -Raw | ConvertFrom-Json -Depth 20
    Assert-True (@($roleCatalog.packs).Count -eq 4) (
        'The compact catalog should contain four industry packs.'
    )
    foreach ($rolePack in @($roleCatalog.packs)) {
        $packRoles = @(Get-Content -LiteralPath (
            Join-Path (Join-Path $skillRoot 'references') $rolePack.file
        ) -Raw | ConvertFrom-Json -Depth 50)
        Assert-True ($packRoles.Count -ge 3 -and $packRoles.Count -le 4) (
            "Role pack '$($rolePack.id)' should contain three or four roles."
        )
        Assert-True (@($packRoles.id | Select-Object -Unique).Count -eq $packRoles.Count) (
            "Role pack '$($rolePack.id)' should use unique role IDs."
        )
        foreach ($presetRole in $packRoles) {
            foreach ($field in @(
                'id', 'display_name', 'mission', 'responsibilities', 'non_goals',
                'required_inputs', 'deliverables', 'evidence_rules',
                'tool_policy', 'question_policy', 'escalation_conditions',
                'identity_statement', 'user_defined'
            )) {
                Assert-True ($null -ne $presetRole.PSObject.Properties[$field]) (
                    "Preset role '$($presetRole.id)' requires '$field'."
                )
            }
        }
    }
    $equityRole = & (Join-Path $scriptRoot 'Get-AgentRolePreset.ps1') `
        -Domain 'equity-research' -RoleId 'valuation-analyst'
    Assert-True ($equityRole -like '*valuation-analyst*') (
        'An exact role query should return the selected contract.'
    )
    Assert-True ($equityRole -notlike '*thesis-risk-reviewer*') (
        'An exact role query should not inject neighboring role contracts.'
    )
    $efficiency = & (Join-Path $scriptRoot 'Test-OrchestrationEfficiency.ps1') `
        -PlanPath $examplePath | ConvertFrom-Json
    Assert-True $efficiency.valid 'Example efficiency policy should be valid.'
    Assert-True ($efficiency.decision -eq 'orchestrate') (
        'Valid context-efficiency policy should permit orchestration.'
    )
    Assert-True ($efficiency.maximum_context_overlap_ratio -le 0.5) (
        'Example should stay under the context-overlap ceiling.'
    )
    Assert-True ($efficiency.receipt -like '*reference-first*') (
        'Efficiency receipt should expose the context strategy.'
    )
    $baselineMetricsPath = Join-Path $testRoot 'baseline-metrics.json'
    $candidateMetricsPath = Join-Path $testRoot 'candidate-metrics.json'
    $comparisonManifestPath = Join-Path $testRoot 'comparison-manifest.json'
    @{
        task = 'example-case'
        input_manifest = @('source:test-fixture')
        acceptance = @('test:self-test')
        output_scope = 'benchmark receipt'
        environment = 'local-test'
        tool_policy = 'same'
        cache_policy = 'fresh'
        failure_policy = 'same'
    } | ConvertTo-Json | Set-Content -LiteralPath $comparisonManifestPath
    $comparisonFingerprint = (
        Get-FileHash -LiteralPath $comparisonManifestPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    @{
        case_id = 'example-case'
        comparison_manifest_path = $comparisonManifestPath
        comparison_fingerprint = $comparisonFingerprint
        variant = 'single-agent'
        input_tokens = 40000
        output_tokens = 10000
        useful_output_tokens = 7000
        coordination_tokens = 0
        repeated_tokens = 3000
        recovery_tokens = 0
        wall_clock_seconds = 120
        quality_score = 90
    } | ConvertTo-Json | Set-Content -LiteralPath $baselineMetricsPath
    @{
        case_id = 'example-case'
        comparison_manifest_path = $comparisonManifestPath
        comparison_fingerprint = $comparisonFingerprint
        variant = 'adaptive-agent-orchestrator'
        input_tokens = 25000
        output_tokens = 8000
        useful_output_tokens = 6500
        coordination_tokens = 2000
        repeated_tokens = 2000
        recovery_tokens = 1000
        wall_clock_seconds = 90
        quality_score = 91
    } | ConvertTo-Json | Set-Content -LiteralPath $candidateMetricsPath
    $benchmark = & (Join-Path $scriptRoot 'Test-OrchestrationBenchmark.ps1') `
        -BaselinePath $baselineMetricsPath -CandidatePath $candidateMetricsPath |
        ConvertFrom-Json
    Assert-True $benchmark.passed 'Efficient candidate benchmark should pass.'
    Assert-True ($benchmark.token_savings_ratio -ge 0.2) (
        'Benchmark should report material Token savings.'
    )
    Assert-True ($benchmark.recovery_tokens -eq 1000) (
        'Benchmark must expose recovery cost.'
    )
    $forgedMetricsPath = Join-Path $testRoot 'forged-metrics.json'
    $forgedMetrics = Get-Content -LiteralPath $candidateMetricsPath -Raw |
        ConvertFrom-Json -AsHashtable
    $forgedMetrics.comparison_fingerprint = ('f' * 64)
    $forgedMetrics | ConvertTo-Json |
        Set-Content -LiteralPath $forgedMetricsPath
    $forgedFingerprintCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationBenchmark.ps1') `
            -BaselinePath $baselineMetricsPath `
            -CandidatePath $forgedMetricsPath | Out-Null
    }
    catch {
        $forgedFingerprintCaught = $_.Exception.Message -like (
            '*does not match its manifest file*'
        )
    }
    Assert-True $forgedFingerprintCaught (
        'Benchmark fingerprints must be derived from an actual manifest file.'
    )
    $baselineSuitePath = Join-Path $testRoot 'baseline-suite.json'
    $candidateSuitePath = Join-Path $testRoot 'candidate-suite.json'
    $suiteManifests = @{}
    foreach ($caseId in @('a', 'b', 'c')) {
        $manifestPath = Join-Path $testRoot "comparison-$caseId.json"
        @{
            task = "suite-$caseId"
            input_manifest = @("source:fixture-$caseId")
            acceptance = @("test:case-$caseId")
            output_scope = 'benchmark receipt'
            environment = 'local-test'
            tool_policy = 'same'
            cache_policy = 'fresh'
            failure_policy = 'same'
        } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath
        $suiteManifests[$caseId] = @{
            path = $manifestPath
            hash = (
                Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256
            ).Hash.ToLowerInvariant()
        }
    }
    @(
        @{ case_id = 'a'; comparison_manifest_path = $suiteManifests.a.path; comparison_fingerprint = $suiteManifests.a.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 90 },
        @{ case_id = 'b'; comparison_manifest_path = $suiteManifests.b.path; comparison_fingerprint = $suiteManifests.b.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 91 },
        @{ case_id = 'c'; comparison_manifest_path = $suiteManifests.c.path; comparison_fingerprint = $suiteManifests.c.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 92 }
    ) | ConvertTo-Json | Set-Content -LiteralPath $baselineSuitePath
    @(
        @{ case_id = 'a'; comparison_manifest_path = $suiteManifests.a.path; comparison_fingerprint = $suiteManifests.a.hash; input_tokens = 5500; output_tokens = 1500; quality_score = 90 },
        @{ case_id = 'b'; comparison_manifest_path = $suiteManifests.b.path; comparison_fingerprint = $suiteManifests.b.hash; input_tokens = 6000; output_tokens = 1500; quality_score = 91 },
        @{ case_id = 'c'; comparison_manifest_path = $suiteManifests.c.path; comparison_fingerprint = $suiteManifests.c.hash; input_tokens = 6500; output_tokens = 1500; quality_score = 92 }
    ) | ConvertTo-Json | Set-Content -LiteralPath $candidateSuitePath
    $benchmarkSuite = & (
        Join-Path $scriptRoot 'Test-OrchestrationBenchmarkSuite.ps1'
    ) -BaselinePath $baselineSuitePath -CandidatePath $candidateSuitePath |
        ConvertFrom-Json
    Assert-True $benchmarkSuite.passed (
        'A benchmark suite with median savings and no P90 regression should pass.'
    )
    Assert-True ($benchmarkSuite.p90_token_ratio -le 1) (
        'Benchmark suite must enforce the P90 no-regression gate.'
    )
    $weakenedBenchmarkGateCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationBenchmarkSuite.ps1') `
            -BaselinePath $baselineSuitePath -CandidatePath $candidateSuitePath `
            -MinimumMedianSavingsRatio 0 | Out-Null
    }
    catch {
        $weakenedBenchmarkGateCaught = $_.Exception.Message -like (
            '*MinimumMedianSavingsRatio*'
        )
    }
    Assert-True $weakenedBenchmarkGateCaught (
        'Release benchmark thresholds must not be weakened by parameters.'
    )
    $duplicateBaselineSuitePath = Join-Path $testRoot (
        'duplicate-baseline-suite.json'
    )
    @(
        @{ case_id = 'a'; comparison_manifest_path = $suiteManifests.a.path; comparison_fingerprint = $suiteManifests.a.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 90 },
        @{ case_id = 'a'; comparison_manifest_path = $suiteManifests.a.path; comparison_fingerprint = $suiteManifests.a.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 90 },
        @{ case_id = 'c'; comparison_manifest_path = $suiteManifests.c.path; comparison_fingerprint = $suiteManifests.c.hash; input_tokens = 8000; output_tokens = 2000; quality_score = 92 }
    ) | ConvertTo-Json | Set-Content -LiteralPath $duplicateBaselineSuitePath
    $duplicateBaselineCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationBenchmarkSuite.ps1') `
            -BaselinePath $duplicateBaselineSuitePath `
            -CandidatePath $candidateSuitePath | Out-Null
    }
    catch {
        $duplicateBaselineCaught = $_.Exception.Message -like (
            '*Duplicate baseline case_id*'
        )
    }
    Assert-True $duplicateBaselineCaught (
        'Benchmark suites must reject duplicated baseline cases.'
    )

    $handoffPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $handoffPlan.nodes[0].context.handoff_required = $true
    $handoffPlan.nodes[0].context.handoff_path =
        'artifacts/handoffs/draft.json'
    $handoffPlan.nodes[0].context.handoff_max_chars = 4000
    $handoffPlanPath = Join-Path $testRoot 'handoff-plan.json'
    $handoffPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $handoffPlanPath

    $runDirectory = Join-Path $testRoot 'run'
    $initial = & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $handoffPlanPath -RunDirectory $runDirectory `
        -WorkspaceRoot $testRoot | ConvertFrom-Json
    Assert-True ('draft' -in @($initial.ready_nodes)) 'Draft should initially be ready.'
    Assert-True ('review' -notin @($initial.ready_nodes)) 'Review should wait for draft.'

    $waveBindingRun = Join-Path $testRoot 'wave-binding-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $waveBindingRun `
        -WorkspaceRoot $testRoot | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $waveBindingRun -NodeId 'draft' `
        -Status 'launch_reserved' -Message 'attempt forged wave' -Wave 99 `
        -IdempotencyKey 'wave-binding-draft' | Out-Null
    $waveBindingEvent = Get-Content -LiteralPath (
        Join-Path $waveBindingRun 'events.jsonl'
    ) | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($waveBindingEvent.wave -eq 1) (
        'Runtime events must use the immutable plan wave, not caller input.'
    )

    $coordinationDoubleCountCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' -Status 'launch_reserved' `
            -Message 'invalid standalone coordination usage' `
            -CoordinationTokensDelta 10 -UsageSource 'estimate' `
            -IdempotencyKey 'draft-invalid-coordination' | Out-Null
    }
    catch {
        $coordinationDoubleCountCaught = $_.Exception.Message -like (
            '*must be a subset*'
        )
    }
    Assert-True $coordinationDoubleCountCaught (
        'Coordination diagnostics must not be counted outside total usage.'
    )

    $dependencyCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status 'launch_reserved' `
            -Message 'start review too early' -IdempotencyKey 'review-too-early' |
            Out-Null
    }
    catch {
        $dependencyCaught = $_.Exception.Message -like '*before dependency*'
    }
    Assert-True $dependencyCaught 'A node must not launch before dependencies validate.'

    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized',
        'running', 'completed', 'validated'
    )) {
        $threadId = if ($status -eq 'materialized') { 'test-thread-draft' } else { $null }
        $artifact = if ($status -eq 'completed') {
            'artifacts/draft/output.md'
        } else { $null }
        $evidence = if ($status -eq 'completed') {
            @('artifact:artifacts/draft/output.md')
        } else { @() }
        $inputTokensDelta = if ($status -eq 'completed') { 1200 } else { 0 }
        $outputTokensDelta = if ($status -eq 'completed') { 600 } else { 0 }
        $coordinationTokensDelta = if ($status -eq 'completed') { 100 } else { 0 }
        $usageSource = if ($status -eq 'completed') { 'estimate' } else { 'none' }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' -Status $status `
            -Message "draft $status" -ThreadId $threadId -Artifact $artifact `
            -Evidence $evidence -InputTokensDelta $inputTokensDelta `
            -OutputTokensDelta $outputTokensDelta `
            -CoordinationTokensDelta $coordinationTokensDelta `
            -UsageSource $usageSource `
            -IdempotencyKey "draft-1-$status" | Out-Null
    }
    $afterDraft = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $runDirectory | ConvertFrom-Json
    Assert-True ('review' -notin @($afterDraft.ready_nodes)) (
        'Validation alone must not unlock a dependent worker before adoption.'
    )
    $draftState = $afterDraft.nodes | Where-Object { $_.id -eq 'draft' }
    Assert-True ($draftState.thread_id -eq 'test-thread-draft') (
        'Reducer should retain the last non-null thread id.'
    )
    Assert-True ($draftState.artifact -eq 'artifacts/draft/output.md') (
        'Reducer should retain the last non-null artifact.'
    )
    Assert-True ($afterDraft.usage.total_tokens -eq 1800) (
        'Reducer should sum input and output without re-adding coordination.'
    )
    $draftHandoff = & (Join-Path $scriptRoot 'New-ThreadHandoff.ps1') `
        -RunDirectory $runDirectory -NodeId 'draft' `
        -Summary 'The draft defines interfaces, limits, and failure handling.' `
        -Decisions @('Use one controller') `
        -Evidence @('artifact:artifacts/draft/output.md') `
        -UnresolvedRisks @('Runtime adapter remains pending') `
        -RiskDisposition 'mitigated' `
        -NextAction 'Give the validated draft to the review node.' |
        ConvertFrom-Json
    Assert-True ($draftHandoff.handoff.continuity_key -eq 'architecture-proposal') (
        'Handoff should retain the declared continuity key.'
    )
    Assert-True ($draftHandoff.handoff_sha256 -match '^[0-9a-f]{64}$') (
        'Handoff creation should return a SHA-256 binding.'
    )
    Assert-True (Test-Path -LiteralPath (
        Join-Path $testRoot 'artifacts\handoffs\draft.json'
    )) 'Handoff should be written to the declared project-relative path.'
    $handoffOverwriteCaught = $false
    try {
        & (Join-Path $scriptRoot 'New-ThreadHandoff.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' `
            -Summary 'Attempt to replace the original handoff.' `
            -Evidence @('artifact:artifacts/draft/output.md') `
            -RiskDisposition 'none' -NextAction 'Do not replace it.' | Out-Null
    }
    catch {
        $handoffOverwriteCaught = $_.Exception.Message -like '*immutable*'
    }
    Assert-True $handoffOverwriteCaught 'A handoff must be immutable once written.'

    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'draft' -Status 'adopted' `
        -Message 'adopted because the draft closes the required architecture gap' `
        -IdempotencyKey 'draft-1-adopted' | Out-Null
    $afterDraftAdoption = & (
        Join-Path $scriptRoot 'Get-OrchestrationState.ps1'
    ) -RunDirectory $runDirectory | ConvertFrom-Json
    Assert-True ('review' -in @($afterDraftAdoption.ready_nodes)) (
        'A dependent worker should become ready only after explicit adoption.'
    )

    $reviewReservation = & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'review' -Status 'launch_reserved' `
        -Message 'review reserved' -IdempotencyKey 'review-1-reserved' |
        ConvertFrom-Json
    $reviewReservationAgain = & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'review' -Status 'launch_reserved' `
        -Message 'review reserved' -IdempotencyKey 'review-1-reserved' |
        ConvertFrom-Json
    Assert-True ($reviewReservation.sequence -eq $reviewReservationAgain.sequence) (
        'Repeated idempotency keys should return the original event.'
    )
    $idempotencyCollisionCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status 'launch_reserved' `
            -Message 'changed payload' -IdempotencyKey 'review-1-reserved' |
            Out-Null
    }
    catch {
        $idempotencyCollisionCaught = $_.Exception.Message -like '*already used*'
    }
    Assert-True $idempotencyCollisionCaught (
        'An idempotency key must not accept a different request payload.'
    )

    $packet = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
        -PlanPath $examplePath -NodeId 'review' -WorkspaceRoot $testRoot
    Assert-True ($packet -like '*I challenge the proposal independently*') (
        'Rendered packets should contain the role identity.'
    )
    Assert-True ($packet -like '*Maximum questions: 2*') (
        'Rendered packets should contain the role question limit.'
    )
    Assert-True ($packet -like '*No workspace writes*') (
        'Rendered packets should contain the effective write boundary.'
    )
    Assert-True ($packet -like '*Session: fresh*') (
        'Rendered packets should contain the session policy.'
    )
    Assert-True ($packet -like '*Exclude:*') (
        'Rendered packets should contain explicit context exclusions.'
    )
    Assert-True ($packet -like '*Read only these references:*') (
        'Rendered packets should direct reference-first context loading.'
    )
    Assert-True ($packet -notlike '*Selection reason:*') (
        'Controller-only selection reasons must not inflate worker packets.'
    )
    Assert-True ($packet -like '*Handoff: none*') (
        'A node without handoff_required should not be told to write one.'
    )
    Assert-True ($packet -like '*Do not restate inputs*') (
        'Rendered packets should make context-minimization rules operational.'
    )
    $startupRetryPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $startupRetryPlan.limits.retry_reserve = 0
    $startupRetryPlan.nodes[0].max_attempts = 2
    $startupRetryPlanPath = Join-Path $testRoot 'startup-retry-plan.json'
    $startupRetryPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $startupRetryPlanPath
    $startupRetryRun = Join-Path $testRoot 'startup-retry-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $startupRetryPlanPath -RunDirectory $startupRetryRun `
        -WorkspaceRoot $skillRoot | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $startupRetryRun -NodeId 'draft' `
        -Status 'launch_reserved' -Message 'first startup reserved' `
        -IdempotencyKey 'startup-first-reserved' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $startupRetryRun -NodeId 'draft' `
        -Status 'materializing' -Message 'first startup materializing' `
        -IdempotencyKey 'startup-first-materializing' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $startupRetryRun -NodeId 'draft' -Status 'failed' `
        -Message 'health probe confirmed no worker' `
        -ErrorClass 'startup_unmaterialized' `
        -IdempotencyKey 'startup-first-failed' | Out-Null
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $startupRetryRun -NodeId 'draft' `
        -Status 'launch_reserved' -Message 'replacement startup reserved' `
        -IdempotencyKey 'startup-second-reserved' | Out-Null
    $startupRetryState = & (
        Join-Path $scriptRoot 'Get-OrchestrationState.ps1'
    ) -RunDirectory $startupRetryRun | ConvertFrom-Json
    Assert-True ($startupRetryState.launch_attempts -eq 2) (
        'A confirmed unmaterialized startup should permit a replacement attempt.'
    )
    Assert-True ($startupRetryState.materialized_workers -eq 0) (
        'A failed health probe must not count as a materialized Worker.'
    )
    $fullPacket = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
        -PlanPath $examplePath -NodeId 'review' -WorkspaceRoot $testRoot -Full
    Assert-True ($packet.Length -lt ($fullPacket.Length * 0.75)) (
        'Default worker packet should be materially smaller than debug mode.'
    )
    $deltaRun = Join-Path $testRoot 'delta-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $deltaRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @(
        'launch_reserved', 'materializing', 'materialized', 'running'
    )) {
        $threadId = if ($status -eq 'materialized') {
            'delta-failed-thread'
        } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $deltaRun -NodeId 'draft' -Status $status `
            -Message "delta retry $status" -ThreadId $threadId `
            -IdempotencyKey "delta-retry-1-$status" | Out-Null
    }
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $deltaRun -NodeId 'draft' -Status 'failed' `
        -Message 'draft output failed validation' -ErrorClass 'output_invalid' `
        -IdempotencyKey 'delta-retry-1-failed' | Out-Null
    $deltaPacket = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
        -PlanPath $examplePath -NodeId 'draft' -WorkspaceRoot $testRoot `
        -RetryOutputRef 'artifact:artifacts/draft/output.md' `
        -FailureEvidence 'test:draft-schema-failed' `
        -RepairInstruction 'Add the missing failure-handling section.' `
        -RetryRunDirectory $deltaRun
    Assert-True ($deltaPacket.Length -lt ($packet.Length * 0.65)) (
        'Delta retry should be materially smaller than the initial packet.'
    )
    Assert-True ($deltaPacket -notlike '*Read only these references:*') (
        'Delta retry should not replay the original context list.'
    )
    $unboundDeltaCaught = $false
    try {
        & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
            -PlanPath $examplePath -NodeId 'draft' -WorkspaceRoot $testRoot `
            -RetryOutputRef 'artifact:artifacts/draft/output.md' `
            -FailureEvidence 'test:draft-schema-failed' `
            -RepairInstruction 'Add the missing failure-handling section.' |
            Out-Null
    }
    catch {
        $unboundDeltaCaught = $_.Exception.Message -like (
            '*requires RetryRunDirectory*'
        )
    }
    Assert-True $unboundDeltaCaught (
        'Delta retry must bind to a real failed execution.'
    )

    $crowdedFirstWave = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $crowdedFirstWave.nodes[1].wave = 1
    Assert-InvalidPlan $crowdedFirstWave 'crowded-first-wave' (
        'Wave 1 may contain only one worker'
    )

    $missingRoleActivation = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingRoleActivation.nodes[0].Remove('role_activation')
    Assert-InvalidPlan $missingRoleActivation 'missing-role-activation' (
        'requires role_activation'
    )

    $invalidRoleDisposition = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidRoleDisposition.nodes[0].role_activation.user_disposition = 'assumed'
    Assert-InvalidPlan $invalidRoleDisposition 'invalid-role-disposition' (
        'must be approved or auto-authorized'
    )

    $missingAuthorizationEvidence = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingAuthorizationEvidence.nodes[0].role_activation.Remove(
        'authorization_evidence'
    )
    Assert-InvalidPlan $missingAuthorizationEvidence (
        'missing-authorization-evidence'
    ) 'requires non-empty authorization_evidence'

    $wrongAuthorizationEvidence = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $wrongAuthorizationEvidence.nodes[0].role_activation.user_disposition = (
        'auto-authorized'
    )
    Assert-InvalidPlan $wrongAuthorizationEvidence (
        'wrong-authorization-evidence'
    ) 'requires authorization_evidence formatted as policy:path:<file>'

    $missingAuthorizationPolicy = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingAuthorizationPolicy.nodes[0].role_activation.user_disposition = (
        'auto-authorized'
    )
    $missingAuthorizationPolicy.nodes[0].role_activation.authorization_evidence = (
        'policy:path:missing-policy.md'
    )
    Assert-InvalidPlan $missingAuthorizationPolicy (
        'missing-authorization-policy'
    ) 'authorization policy does not exist'

    $validAuthorizationPolicy = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $validAuthorizationPolicy.nodes[0].role_activation.user_disposition = (
        'auto-authorized'
    )
    $validAuthorizationPolicy.nodes[0].role_activation.authorization_evidence = (
        'policy:path:SKILL.md'
    )
    $validAuthorizationPolicyPath = Join-Path $testRoot (
        'valid-authorization-policy.json'
    )
    $validAuthorizationPolicy | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $validAuthorizationPolicyPath
    $validAuthorizationResult = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $validAuthorizationPolicyPath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $validAuthorizationResult.valid (
        'Auto-authorization should accept a real project policy file.'
    )
    $missingWorkspaceRootCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
            -PlanPath $validAuthorizationPolicyPath | Out-Null
    }
    catch {
        $missingWorkspaceRootCaught = $_.Exception.Message -like (
            '*requires -WorkspaceRoot to verify its policy*'
        )
    }
    Assert-True $missingWorkspaceRootCaught (
        'Auto-authorization must not validate without a policy workspace root.'
    )

    $validManuscript = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $validManuscript.manuscript_profile = @{
        mode = 'coauthoring'
        lead_author_node_id = 'integrate'
        lead_author_owns = @(
            'argument-spine', 'abstract', 'conclusion', 'final-merge'
        )
    }
    $validManuscript.nodes[0].manuscript_contribution = @{
        mode = 'co-author'
        section_scope = 'Architecture methods section'
    }
    $validManuscript.nodes[1].manuscript_contribution = @{
        mode = 'independent-review'
    }
    $validManuscriptPath = Join-Path $testRoot 'valid-manuscript.json'
    $validManuscript | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $validManuscriptPath
    $validManuscriptResult = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $validManuscriptPath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $validManuscriptResult.valid (
        'A bounded co-author plus independent reviewer manuscript should pass.'
    )

    $reviewOnlyCoauthoring = Get-Content -LiteralPath (
        $validManuscriptPath
    ) -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $reviewOnlyCoauthoring.nodes[0].manuscript_contribution = @{
        mode = 'research'
    }
    Assert-InvalidPlan $reviewOnlyCoauthoring 'review-only-coauthoring' (
        'requires at least one co-author'
    )

    $readOnlyCoauthor = Get-Content -LiteralPath $validManuscriptPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $readOnlyCoauthor.nodes[1].manuscript_contribution = @{
        mode = 'co-author'
        section_scope = 'Review-authored methods section'
    }
    Assert-InvalidPlan $readOnlyCoauthor 'read-only-manuscript-coauthor' (
        'must use a proposal-only or scoped-write role'
    )

    $excessWorkerLimit = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $excessWorkerLimit.limits.max_total_agent_nodes = 5
    Assert-InvalidPlan $excessWorkerLimit 'excess-worker-limit' (
        'max_total_agent_nodes must be between 1 and 4'
    )

    $overlappingContext = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $overlappingContext.nodes[1].context.inputs =
        @($overlappingContext.nodes[0].context.inputs)
    Assert-InvalidPlan $overlappingContext 'overlapping-context' (
        'Context overlap'
    )

    $untypedContext = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $untypedContext.nodes[0].context.inputs = @('Plan goal')
    Assert-InvalidPlan $untypedContext 'untyped-context' (
        'context inputs must be typed references'
    )

    $broadContext = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $broadContext.nodes[0].context.inputs = @('path:.')
    Assert-InvalidPlan $broadContext 'broad-context' (
        'uses broad context reference'
    )

    $missingSelectionReason = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingSelectionReason.nodes[0].context.Remove('selection_reason')
    $missingSelectionReasonPath = Join-Path $testRoot 'optional-selection-reason.json'
    $missingSelectionReason | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $missingSelectionReasonPath
    $optionalSelectionReason = & (
        Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1'
    ) -PlanPath $missingSelectionReasonPath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $optionalSelectionReason.valid (
        'selection_reason should remain optional controller metadata.'
    )

    $unneededHandoffFields = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unneededHandoffFields.nodes[1].context.handoff_path =
        'artifacts/handoffs/unneeded.json'
    $unneededHandoffFields.nodes[1].context.handoff_max_chars = 2000
    Assert-InvalidPlan $unneededHandoffFields 'unneeded-handoff-fields' (
        'without handoff_required cannot set'
    )

    $weakOverlapPolicy = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $weakOverlapPolicy.efficiency.max_context_overlap_ratio = 0.9
    Assert-InvalidPlan $weakOverlapPolicy 'weak-overlap-policy' (
        'cannot exceed 0.5'
    )

    $unearnedNextWave = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unearnedNextWave.nodes[1].depends_on = @()
    Assert-InvalidPlan $unearnedNextWave 'unearned-next-wave' (
        'must depend on an earlier adopted result or own disjoint context'
    )

    $disjointNextWave = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $disjointNextWave.nodes[1].depends_on = @()
    $disjointNextWave.nodes[1].context.inputs = @(
        'source:independent-security-advisory'
    )
    $disjointNextWavePath = Join-Path $testRoot 'disjoint-next-wave.json'
    $disjointNextWave | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $disjointNextWavePath
    $disjointEfficiency = & (
        Join-Path $scriptRoot 'Test-OrchestrationEfficiency.ps1'
    ) -PlanPath $disjointNextWavePath | ConvertFrom-Json
    Assert-True $disjointEfficiency.valid (
        'A later worker with truly disjoint context should not need a fake dependency.'
    )
    $disjointWaveRun = Join-Path $testRoot 'disjoint-wave-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $disjointNextWavePath -RunDirectory $disjointWaveRun `
        -WorkspaceRoot $skillRoot | Out-Null
    $earlyDisjointWaveCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $disjointWaveRun -NodeId 'review' `
            -Status 'launch_reserved' -Message 'start wave 2 too early' `
            -IdempotencyKey 'disjoint-wave-too-early' | Out-Null
    }
    catch {
        $earlyDisjointWaveCaught = $_.Exception.Message -like (
            '*cannot start before earlier-wave node*'
        )
    }
    Assert-True $earlyDisjointWaveCaught (
        'Disjoint context must not let a later wave bypass progressive dispatch.'
    )

    $fullRetryPolicy = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $fullRetryPolicy.efficiency.retry_strategy = 'full'
    Assert-InvalidPlan $fullRetryPolicy 'full-retry-policy' (
        'retry_strategy must be delta'
    )

    $missingDependency = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingDependency.nodes[1].depends_on = @('does-not-exist')
    Assert-InvalidPlan $missingDependency 'missing-dependency' 'depends on missing node'

    $recursiveWorker = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $recursiveWorker.nodes[0].allow_delegation = $true
    Assert-InvalidPlan $recursiveWorker 'recursive-worker' 'allow_delegation'

    $unjustifiedUltra = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unjustifiedUltra.nodes[1].capability = 'ultra'
    Assert-InvalidPlan $unjustifiedUltra 'unjustified-ultra' 'requires ultra_reason'

    $automaticUltra = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $automaticUltra.nodes[1].capability = 'ultra'
    $automaticUltra.nodes[1].effort = 'ultra'
    $automaticUltra.nodes[1].ultra_reason = 'A cheaper attempt failed.'
    $automaticUltra.nodes[1].ultra_authorization = 'escalated-after-failure'
    $automaticUltra.nodes[1].prior_attempt_node_id = 'draft'
    Assert-InvalidPlan $automaticUltra 'automatic-ultra' 'user-requested'

    $economyUltra = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $economyUltra.nodes[1].capability = 'ultra'
    $economyUltra.nodes[1].effort = 'ultra'
    $economyUltra.nodes[1].ultra_reason = 'The user explicitly requested it.'
    $economyUltra.nodes[1].ultra_authorization = 'user-requested'
    Assert-InvalidPlan $economyUltra 'economy-ultra' 'Lean profile forbids Ultra'

    $overlappingWriters = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $overlappingWriters.nodes[1].read_only = $false
    $overlappingWriters.nodes[1].write_scope = @('artifacts')
    Assert-InvalidPlan $overlappingWriters 'overlapping-writers' 'Write scope overlap'

    $pathTraversal = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $pathTraversal.nodes[0].write_scope = @('artifacts/../secrets')
    Assert-InvalidPlan $pathTraversal 'path-traversal' "cannot traverse with '..'"

    $invalidGate = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidGate.nodes += @{
        id = 'approve'
        kind = 'human-gate'
        depends_on = @('review')
        question = 'Publish now?'
        choices = @('publish', 'stop')
        default_safe_action = 'publish'
        action_class = 'external-write'
    }
    $invalidGate.completion.required_nodes += 'approve'
    Assert-InvalidPlan $invalidGate 'invalid-gate' 'must default to stop'

    $mainOverlap = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $mainOverlap.nodes[2].write_scope = @('artifacts')
    Assert-InvalidPlan $mainOverlap 'main-overlap' 'Write scope overlap'

    $roleWriteEscalation = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $roleWriteEscalation.nodes[1].read_only = $false
    $roleWriteEscalation.nodes[1].write_scope = @('artifacts/reviewer-write')
    Assert-InvalidPlan $roleWriteEscalation 'role-write-escalation' (
        "cannot write under role 'adversarial-reviewer'"
    )

    $trailingDotScope = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $trailingDotScope.nodes[0].write_scope = @('artifacts/draft.')
    Assert-InvalidPlan $trailingDotScope 'trailing-dot-scope' 'Windows path alias'

    $emptyArtifactThreshold = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $emptyArtifactThreshold.completion.artifact_checks[0].minimum_items = 0
    Assert-InvalidPlan $emptyArtifactThreshold 'empty-artifact-threshold' (
        'minimum_items >= 1'
    )

    $missingContext = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingContext.nodes[0].Remove('context')
    Assert-InvalidPlan $missingContext 'missing-context' 'context.session_policy'

    $nativeReuse = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $nativeReuse.nodes[1].context.session_policy = 'reuse'
    $nativeReuse.nodes[1].context.max_prior_turns = 2
    $nativeReuse.nodes[1].context.prior_thread_id = 'old-thread'
    $nativeReuse.nodes[1].context.prior_handoff = 'artifacts/handoffs/old.json'
    $nativeReuse.nodes[1].context.reuse_reason = 'same workstream'
    Assert-InvalidPlan $nativeReuse 'native-reuse' 'Only background-thread'

    $reuseWithoutHash = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $reuseWithoutHash.nodes[0].context.session_policy = 'reuse'
    $reuseWithoutHash.nodes[0].context.max_prior_turns = 2
    $reuseWithoutHash.nodes[0].context.prior_thread_id = 'old-thread'
    $reuseWithoutHash.nodes[0].context.prior_handoff = 'artifacts/handoffs/old.json'
    $reuseWithoutHash.nodes[0].context.reuse_reason = 'same bounded workstream'
    Assert-InvalidPlan $reuseWithoutHash 'reuse-without-hash' 'prior_handoff_hash'

    $freshWithReuseField = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $freshWithReuseField.nodes[0].context.reuse_reason = 'stale context'
    Assert-InvalidPlan $freshWithReuseField 'fresh-with-reuse-field' (
        'cannot set context.reuse_reason'
    )

    $missingRole = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $missingRole.nodes[0].role_id = 'does-not-exist'
    Assert-InvalidPlan $missingRole 'missing-role' 'references missing role'

    $invalidRole = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidRole.roles[0].non_goals = @()
    Assert-InvalidPlan $invalidRole 'invalid-role' 'non_goals'

    $invalidLifetime = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidLifetime.roles[0].lifetime = 'forever'
    Assert-InvalidPlan $invalidLifetime 'invalid-role-lifetime' (
        'lifetime must be task, project, or user-owned'
    )

    $unownedUserRole = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $unownedUserRole.roles[0].lifetime = 'user-owned'
    Assert-InvalidPlan $unownedUserRole 'unowned-user-role' (
        'user-owned lifetime requires user_defined true'
    )

    $generatedRole = & (Join-Path $scriptRoot 'New-AgentRole.ps1') `
        -Id 'inventory-auditor' -DisplayName 'Inventory Auditor' `
        -Mission 'Find unsupported inventory claims.' `
        -Responsibilities @('Inspect evidence') -NonGoals @('Modify production data') `
        -RequiredInputs @('Inventory report') -Deliverables @('Finding list') `
        -EvidenceRules @('Cite each source row') -ToolPolicy 'read-only' `
        -Lifetime 'user-owned' `
        -EscalationConditions @('Source data is missing') `
        -IdentityStatement 'You are an evidence-first inventory auditor.' `
        -UserDefined | ConvertFrom-Json
    Assert-True ($generatedRole.id -eq 'inventory-auditor') (
        'Role generator should preserve the requested id.'
    )
    Assert-True $generatedRole.user_defined (
        'Role generator should mark a custom role as user-defined.'
    )
    Assert-True ($generatedRole.lifetime -eq 'user-owned') (
        'Role generator should preserve the requested lifetime.'
    )

    $illegalTransitionCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status 'adopted' `
            -Message 'skip every gate' -IdempotencyKey 'review-skip-adopted' |
            Out-Null
    }
    catch {
        $illegalTransitionCaught = $_.Exception.Message -like '*Illegal state transition*'
    }
    Assert-True $illegalTransitionCaught 'Illegal state transition should be rejected.'

    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'review' -Status 'materializing' `
        -Message 'review materializing' `
        -IdempotencyKey 'review-1-materializing' | Out-Null
    $freshReuseCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status 'materialized' `
            -Message 'reuse draft thread' -ThreadId 'test-thread-draft' `
            -IdempotencyKey 'review-reused-thread' | Out-Null
    }
    catch {
        $freshReuseCaught = $_.Exception.Message -like '*cannot reuse thread*'
    }
    Assert-True $freshReuseCaught 'Fresh nodes must not reuse another node thread.'
    foreach ($status in @('materialized', 'running', 'completed', 'validated')) {
        $threadId = if ($status -eq 'materialized') { 'test-thread-review' } else { $null }
        $evidence = if ($status -eq 'completed') {
            @('observation:Review contains reproducible failure scenarios.')
        } else { @() }
        $inputTokensDelta = if ($status -eq 'completed') { 700 } else { 0 }
        $outputTokensDelta = if ($status -eq 'completed') { 400 } else { 0 }
        $coordinationTokensDelta = if ($status -eq 'completed') { 100 } else { 0 }
        $usageSource = if ($status -eq 'completed') { 'estimate' } else { 'none' }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status $status `
            -Message "review $status" -ThreadId $threadId -Evidence $evidence `
            -InputTokensDelta $inputTokensDelta `
            -OutputTokensDelta $outputTokensDelta `
            -CoordinationTokensDelta $coordinationTokensDelta `
            -UsageSource $usageSource `
            -IdempotencyKey "review-1-$status" | Out-Null
    }
    $unneededHandoffCaught = $false
    try {
        & (Join-Path $scriptRoot 'New-ThreadHandoff.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' `
            -Summary ('x' * 5000) `
            -Evidence @('observation:Review contains reproducible failure scenarios.') `
            -RiskDisposition 'none' `
            -NextAction 'Return the finding.' | Out-Null
    }
    catch {
        $unneededHandoffCaught = $_.Exception.Message -like '*does not require a handoff*'
    }
    Assert-True $unneededHandoffCaught (
        'A node without handoff_required must not create a handoff artifact.'
    )
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $runDirectory -NodeId 'review' -Status 'adopted' `
        -Message 'adopted because the findings close the verification gap' `
        -IdempotencyKey 'review-1-adopted' | Out-Null
    foreach ($status in @('running', 'completed', 'validated')) {
        $evidence = if ($status -eq 'completed') {
            @('observation:Every review finding has a recorded disposition.')
        } else { @() }
        $inputTokensDelta = if ($status -eq 'completed') { 500 } else { 0 }
        $outputTokensDelta = if ($status -eq 'completed') { 600 } else { 0 }
        $coordinationTokensDelta = if ($status -eq 'completed') { 100 } else { 0 }
        $usageSource = if ($status -eq 'completed') { 'estimate' } else { 'none' }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'integrate' -Status $status `
            -Message "integrate $status" -Evidence $evidence `
            -InputTokensDelta $inputTokensDelta `
            -OutputTokensDelta $outputTokensDelta `
            -CoordinationTokensDelta $coordinationTokensDelta `
            -UsageSource $usageSource `
            -IdempotencyKey "integrate-1-$status" | Out-Null
    }
    $missingArtifactCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $runDirectory | Out-Null
    }
    catch {
        $missingArtifactCaught = $_.Exception.Message -like '*artifact is missing*'
    }
    Assert-True $missingArtifactCaught (
        'Completion must fail when a required artifact is missing.'
    )
    $finalDirectory = Join-Path $testRoot 'artifacts\final'
    $null = New-Item -ItemType Directory -Path $finalDirectory
    $emptyDirectoryCaught = $false
    try {
        & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
            -RunDirectory $runDirectory | Out-Null
    }
    catch {
        $emptyDirectoryCaught = $_.Exception.Message -like '*fewer than minimum_items*'
    }
    Assert-True $emptyDirectoryCaught (
        'Completion must fail when a required artifact directory is empty.'
    )
    'validated proposal' | Set-Content -LiteralPath (
        Join-Path $finalDirectory 'proposal.md'
    )
    $completion = & (Join-Path $scriptRoot 'Test-OrchestrationCompletion.ps1') `
        -RunDirectory $runDirectory | ConvertFrom-Json
    Assert-True $completion.complete (
        'Completion gate should pass only after nodes, artifacts, and evidence pass.'
    )

    $tamperedPlanRun = Join-Path $testRoot 'tampered-plan-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $tamperedPlanRun `
        -WorkspaceRoot $skillRoot | Out-Null
    $tamperedPlanPath = Join-Path $tamperedPlanRun 'plan.json'
    $tamperedPlan = Get-Content -LiteralPath $tamperedPlanPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $tamperedPlan.goal = 'silently replaced goal'
    $tamperedPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $tamperedPlanPath
    $planTamperCaught = $false
    try {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $tamperedPlanRun | Out-Null
    }
    catch {
        $planTamperCaught = $_.Exception.Message -like '*changed after run creation*'
    }
    Assert-True $planTamperCaught 'Silent plan replacement should be rejected.'

    $gatePlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $gatePlan.run_id = 'gate-test-001'
    $gatePlan.nodes += @{
        id = 'human-approval'
        kind = 'human-gate'
        depends_on = @()
        question = 'Continue with the reversible local step?'
        choices = @('continue', 'stop')
        default_safe_action = 'stop'
        action_class = 'local-reversible'
    }
    $gatePlan.completion.required_nodes += 'human-approval'
    $gatePlanPath = Join-Path $testRoot 'gate-plan.json'
    $gatePlan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $gatePlanPath
    $gateRun = Join-Path $testRoot 'gate-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $gatePlanPath -RunDirectory $gateRun `
        -WorkspaceRoot $skillRoot | Out-Null
    $gateBypassCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $gateRun -NodeId 'human-approval' -Status 'completed' `
            -Message 'bypass user' -IdempotencyKey 'gate-bypass' | Out-Null
    }
    catch {
        $gateBypassCaught = $_.Exception.Message -like '*must enter needs_input*'
    }
    Assert-True $gateBypassCaught 'Human gate must not complete without waiting for input.'
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $gateRun -NodeId 'human-approval' -Status 'needs_input' `
        -Message 'waiting for user' -IdempotencyKey 'gate-waiting' | Out-Null
    $missingHumanCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $gateRun -NodeId 'human-approval' -Status 'completed' `
            -Message 'no actor evidence' -IdempotencyKey 'gate-no-actor' | Out-Null
    }
    catch {
        $missingHumanCaught = $_.Exception.Message -like '*Decision and HumanActor*'
    }
    Assert-True $missingHumanCaught 'Human gate completion requires decision evidence.'
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $gateRun -NodeId 'human-approval' -Status 'completed' `
        -Message 'user selected continue' -IdempotencyKey 'gate-completed' `
        -Decision 'continue' -HumanActor 'user' | Out-Null

    $questionPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $questionPlan.run_id = 'question-limit-001'
    $questionPlan.roles[0].question_policy.max_questions = 0
    $questionPlan.nodes = @($questionPlan.nodes[0])
    $questionPlan.completion.required_nodes = @('draft')
    $questionPlan.completion.evidence_checks = @(
        @{ node_id = 'draft'; minimum_entries = 1 }
    )
    $questionPlanPath = Join-Path $testRoot 'question-plan.json'
    $questionPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $questionPlanPath
    $questionRun = Join-Path $testRoot 'question-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $questionPlanPath -RunDirectory $questionRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @('launch_reserved', 'materializing', 'materialized', 'running')) {
        $threadId = if ($status -eq 'materialized') { 'question-thread' } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $questionRun -NodeId 'draft' -Status $status `
            -Message "question test $status" -ThreadId $threadId `
            -IdempotencyKey "question-$status" | Out-Null
    }
    $questionLimitCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $questionRun -NodeId 'draft' -Status 'needs_input' `
            -Message 'question beyond contract' -IdempotencyKey 'question-denied' |
            Out-Null
    }
    catch {
        $questionLimitCaught = $_.Exception.Message -like '*question limit*'
    }
    Assert-True $questionLimitCaught 'Runtime should enforce the role question limit.'
    $emptyEvidenceCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $questionRun -NodeId 'draft' -Status 'completed' `
            -Message 'unsupported completion' -Evidence @('success') `
            -IdempotencyKey 'question-empty-evidence' | Out-Null
    }
    catch {
        $emptyEvidenceCaught = $_.Exception.Message -like '*kind:value*'
    }
    Assert-True $emptyEvidenceCaught (
        'Completion evidence must use a typed evidence pointer.'
    )

    $metadataRun = Join-Path $testRoot 'metadata-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $metadataRun `
        -WorkspaceRoot $testRoot | Out-Null
    $metadataPath = Join-Path $metadataRun 'run.json'
    $metadata = Get-Content -LiteralPath $metadataPath -Raw |
        ConvertFrom-Json -AsHashtable
    $metadata.policy_version = 'forged'
    $metadata | ConvertTo-Json | Set-Content -LiteralPath $metadataPath
    $metadataTamperCaught = $false
    try {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $metadataRun | Out-Null
    }
    catch {
        $metadataTamperCaught = $_.Exception.Message -like '*metadata is inconsistent*'
    }
    Assert-True $metadataTamperCaught 'run.json metadata tampering should be rejected.'

    $reusePlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $reusePlan.run_id = 'reuse-thread-001'
    $reusePlan.nodes = @($reusePlan.nodes[0])
    $reusePlan.nodes[0].context.session_policy = 'reuse'
    $reusePlan.nodes[0].context.max_prior_turns = 2
    $reusePlan.nodes[0].context.prior_thread_id = 'declared-prior-thread'
    $reusePlan.nodes[0].context.prior_handoff = 'artifacts/handoffs/prior.json'
    $reusePlan.nodes[0].context.prior_handoff_hash = ('0' * 64)
    $reusePlan.nodes[0].context.reuse_reason = 'Continue the same bounded draft.'
    $reusePlan.completion.required_nodes = @('draft')
    $reusePlan.completion.evidence_checks = @(
        @{ node_id = 'draft'; minimum_entries = 1 }
    )
    $reusePlanPath = Join-Path $testRoot 'reuse-plan.json'
    $reusePlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $reusePlanPath
    $reuseRun = Join-Path $testRoot 'reuse-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $reusePlanPath -RunDirectory $reuseRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @('launch_reserved', 'materializing')) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $reuseRun -NodeId 'draft' -Status $status `
            -Message "reuse $status" -IdempotencyKey "reuse-$status" | Out-Null
    }
    $wrongReuseThreadCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $reuseRun -NodeId 'draft' -Status 'materialized' `
            -Message 'wrong prior thread' -ThreadId 'different-thread' `
            -IdempotencyKey 'reuse-wrong-thread' | Out-Null
    }
    catch {
        $wrongReuseThreadCaught = $_.Exception.Message -like '*declared prior_thread_id*'
    }
    Assert-True $wrongReuseThreadCaught (
        'Reuse must materialize the exact declared prior thread.'
    )

    $boundReusePlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $boundReusePlan.run_id = 'bound-reuse-001'
    $boundReusePlan.nodes = @($boundReusePlan.nodes[0])
    $boundReusePlan.nodes[0].context.session_policy = 'reuse'
    $boundReusePlan.nodes[0].context.max_prior_turns = 2
    $boundReusePlan.nodes[0].context.prior_thread_id = 'test-thread-draft'
    $boundReusePlan.nodes[0].context.prior_handoff = (
        'artifacts/handoffs/draft.json'
    )
    $boundReusePlan.nodes[0].context.prior_handoff_hash = (
        $draftHandoff.handoff_sha256
    )
    $boundReusePlan.nodes[0].context.reuse_reason = (
        'Continue only from the validated compact handoff.'
    )
    $boundReusePlan.completion.required_nodes = @('draft')
    $boundReusePlan.completion.evidence_checks = @(
        @{ node_id = 'draft'; minimum_entries = 1 }
    )
    $boundReusePlanPath = Join-Path $testRoot 'bound-reuse-plan.json'
    $boundReusePlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $boundReusePlanPath
    $boundPacket = & (Join-Path $scriptRoot 'New-WorkerPacket.ps1') `
        -PlanPath $boundReusePlanPath -NodeId 'draft' -WorkspaceRoot $testRoot
    Assert-True ($boundPacket -like "*$($draftHandoff.handoff_sha256)*") (
        'Reuse packets must verify and render the exact handoff hash.'
    )

    $freshRetryPlan = Get-Content -LiteralPath $examplePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    $freshRetryPlan.run_id = 'fresh-retry-001'
    $freshRetryPlan.nodes = @($freshRetryPlan.nodes[0])
    $freshRetryPlan.nodes[0].max_attempts = 2
    $freshRetryPlan.completion.required_nodes = @('draft')
    $freshRetryPlan.completion.evidence_checks = @(
        @{ node_id = 'draft'; minimum_entries = 1 }
    )
    $freshRetryPlanPath = Join-Path $testRoot 'fresh-retry-plan.json'
    $freshRetryPlan | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $freshRetryPlanPath
    $freshRetryRun = Join-Path $testRoot 'fresh-retry-run'
    & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $freshRetryPlanPath -RunDirectory $freshRetryRun `
        -WorkspaceRoot $testRoot | Out-Null
    foreach ($status in @('launch_reserved', 'materializing', 'materialized', 'running')) {
        $threadId = if ($status -eq 'materialized') { 'first-attempt-thread' } else { $null }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $freshRetryRun -NodeId 'draft' -Status $status `
            -Message "fresh retry $status" -ThreadId $threadId `
            -IdempotencyKey "fresh-retry-1-$status" | Out-Null
    }
    & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
        -RunDirectory $freshRetryRun -NodeId 'draft' -Status 'failed' `
        -Message 'first attempt failed' -ErrorClass 'runtime_transient' `
        -IdempotencyKey 'fresh-retry-1-failed' | Out-Null
    foreach ($status in @('launch_reserved', 'materializing')) {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $freshRetryRun -NodeId 'draft' -Status $status `
            -Message "fresh retry 2 $status" `
            -IdempotencyKey "fresh-retry-2-$status" | Out-Null
    }
    $sameNodeThreadReuseCaught = $false
    try {
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $freshRetryRun -NodeId 'draft' -Status 'materialized' `
            -Message 'reuse failed attempt thread' -ThreadId 'first-attempt-thread' `
            -IdempotencyKey 'fresh-retry-reused-thread' | Out-Null
    }
    catch {
        $sameNodeThreadReuseCaught = $_.Exception.Message -like '*cannot reuse thread*'
    }
    Assert-True $sameNodeThreadReuseCaught (
        'Fresh retries must rotate away from the failed attempt thread.'
    )

    $eventsPath = Join-Path $runDirectory 'events.jsonl'
    Add-Content -LiteralPath $eventsPath -Value '{"sequence":999,"hash":"tampered"}'
    $tamperCaught = $false
    try {
        & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
            -RunDirectory $runDirectory | Out-Null
    }
    catch {
        $tamperCaught = $_.Exception.Message -like '*sequence gap*'
    }
    Assert-True $tamperCaught 'Tampered journal should be rejected.'

    [pscustomobject]@{
        passed = $true
        assertions = $script:assertionCount
        journal_recovery_verified = $true
        intentional_invalid_cases_rejected = $script:invalidPlanCount
        role_contracts_verified = $true
        worker_packet_verified = $true
        completion_gate_verified = $true
        question_limit_verified = $true
        typed_evidence_verified = $true
        metadata_tamper_rejected = $true
        context_contract_verified = $true
        compact_handoff_verified = $true
        thread_rotation_verified = $true
        dependency_gate_verified = $true
        idempotency_verified = $true
        plan_tamper_rejected = $true
        human_gate_evidence_verified = $true
        illegal_transition_rejected = $true
        journal_tamper_rejected = $true
        context_efficiency_verified = $true
        token_benchmark_verified = $true
        usage_diagnostics_verified = $true
        role_activation_verified = $true
        industry_role_packs_verified = $true
    } | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $resolvedTempRoot = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).Path
        if (-not $resolvedTestRoot.StartsWith(
            $resolvedTempRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Refusing to remove test directory outside TEMP: $resolvedTestRoot"
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
