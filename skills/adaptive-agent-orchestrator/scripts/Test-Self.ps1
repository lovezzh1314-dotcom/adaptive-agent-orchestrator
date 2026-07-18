[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
$examplePath = Join-Path $skillRoot 'references\example-plan.json'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'adaptive-agent-orchestrator-' + [guid]::NewGuid().ToString('N')
)

function Assert-True {
    param(
        [bool] $Condition,
        [string] $Message
    )
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
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot

    $valid = & (Join-Path $scriptRoot 'Test-OrchestrationPlan.ps1') `
        -PlanPath $examplePath -WorkspaceRoot $skillRoot |
        ConvertFrom-Json
    Assert-True $valid.valid 'Example plan should be valid.'
    Assert-True ($valid.agent_node_count -eq 2) 'Example should contain two agent nodes.'

    $runDirectory = Join-Path $testRoot 'run'
    $initial = & (Join-Path $scriptRoot 'New-OrchestrationRun.ps1') `
        -PlanPath $examplePath -RunDirectory $runDirectory `
        -WorkspaceRoot $testRoot | ConvertFrom-Json
    Assert-True ('draft' -in @($initial.ready_nodes)) 'Draft should initially be ready.'
    Assert-True ('review' -notin @($initial.ready_nodes)) 'Review should wait for draft.'

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
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'draft' -Status $status `
            -Message "draft $status" -ThreadId $threadId -Artifact $artifact `
            -Evidence $evidence `
            -IdempotencyKey "draft-1-$status" | Out-Null
    }
    $afterDraft = & (Join-Path $scriptRoot 'Get-OrchestrationState.ps1') `
        -RunDirectory $runDirectory | ConvertFrom-Json
    Assert-True ('review' -in @($afterDraft.ready_nodes)) (
        'Review should become ready after draft validation.'
    )
    $draftState = $afterDraft.nodes | Where-Object { $_.id -eq 'draft' }
    Assert-True ($draftState.thread_id -eq 'test-thread-draft') (
        'Reducer should retain the last non-null thread id.'
    )
    Assert-True ($draftState.artifact -eq 'artifacts/draft/output.md') (
        'Reducer should retain the last non-null artifact.'
    )
    $draftHandoff = & (Join-Path $scriptRoot 'New-ThreadHandoff.ps1') `
        -RunDirectory $runDirectory -NodeId 'draft' `
        -Summary 'The draft defines interfaces, limits, and failure handling.' `
        -Decisions @('Use one controller') `
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
            -RiskDisposition 'none' -NextAction 'Do not replace it.' | Out-Null
    }
    catch {
        $handoffOverwriteCaught = $_.Exception.Message -like '*immutable*'
    }
    Assert-True $handoffOverwriteCaught 'A handoff must be immutable once written.'

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
    Assert-True ($packet -like '*Session policy: fresh*') (
        'Rendered packets should contain the session policy.'
    )
    Assert-True ($packet -like '*Exclude from context*') (
        'Rendered packets should contain explicit context exclusions.'
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

    $generatedRole = & (Join-Path $scriptRoot 'New-AgentRole.ps1') `
        -Id 'inventory-auditor' -DisplayName 'Inventory Auditor' `
        -Mission 'Find unsupported inventory claims.' `
        -Responsibilities @('Inspect evidence') -NonGoals @('Modify production data') `
        -RequiredInputs @('Inventory report') -Deliverables @('Finding list') `
        -EvidenceRules @('Cite each source row') -ToolPolicy 'read-only' `
        -EscalationConditions @('Source data is missing') `
        -IdentityStatement 'You are an evidence-first inventory auditor.' `
        -UserDefined | ConvertFrom-Json
    Assert-True ($generatedRole.id -eq 'inventory-auditor') (
        'Role generator should preserve the requested id.'
    )
    Assert-True $generatedRole.user_defined (
        'Role generator should mark a custom role as user-defined.'
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
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' -Status $status `
            -Message "review $status" -ThreadId $threadId -Evidence $evidence `
            -IdempotencyKey "review-1-$status" | Out-Null
    }
    $oversizedHandoffCaught = $false
    try {
        & (Join-Path $scriptRoot 'New-ThreadHandoff.ps1') `
            -RunDirectory $runDirectory -NodeId 'review' `
            -Summary ('x' * 5000) -RiskDisposition 'none' `
            -NextAction 'Return the finding.' | Out-Null
    }
    catch {
        $oversizedHandoffCaught = $_.Exception.Message -like '*Serialized handoff exceeds*'
    }
    Assert-True $oversizedHandoffCaught (
        'The limit must cover the complete serialized handoff.'
    )
    foreach ($status in @('running', 'completed', 'validated')) {
        $evidence = if ($status -eq 'completed') {
            @('observation:Every review finding has a recorded disposition.')
        } else { @() }
        & (Join-Path $scriptRoot 'Add-OrchestrationEvent.ps1') `
            -RunDirectory $runDirectory -NodeId 'integrate' -Status $status `
            -Message "integrate $status" -Evidence $evidence `
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
        assertions = 53
        journal_recovery_verified = $true
        invalid_cases_rejected = 16
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
