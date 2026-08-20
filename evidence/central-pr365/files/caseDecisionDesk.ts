import type { SupabaseClient } from "@supabase/supabase-js";
import { PACKET_AI_DEPARTMENTS, type PacketAiDepartment } from "@/lib/wa-governance/packetContentInterpretation";

export const WHATSAPP_CASE_TYPES = [
  "UNCLASSIFIED","ORDER","ORDER_CHANGE","CANCELLATION","ENQUIRY","COMPLAINT",
  "PAYMENT_ADVICE","ACCOUNT_QUERY","DISPATCH","SPECIFICATION",
] as const;
export const WHATSAPP_DISCLOSURE_SCOPES = [
  "customer_pricing","moq_carton","payment_terms","delivery_address",
  "previous_orders","account_balance","draft_order","sales_order",
] as const;
export const WHATSAPP_MILESTONES = [
  "REQUEST_RECEIVED","CLARIFICATION_REQUIRED","DRAFT_PREPARED","CUSTOMER_CONFIRMED",
  "PAYMENT_PROOF_RECEIVED","PAYMENT_VERIFIED","PRODUCTION_STARTED","READY_FOR_DISPATCH",
  "DISPATCHED","DELIVERED","EXCEPTION","CANCELLED","CLOSED",
] as const;
export const WHATSAPP_REPLY_PURPOSES = [
  "RECEIPT_ACKNOWLEDGEMENT","OPERATIONAL_MILESTONE","CASE_UPDATE","CASE_CLOSURE",
] as const;
export const WHATSAPP_LEARNING_TYPES = [
  "PRODUCT_ALIAS","CUSTOMER_ALIAS","INTENT_PATTERN","QUANTITY_PATTERN",
] as const;

export type WhatsAppCaseSnapshot = {
  id: string;
  packet_id: string;
  case_type: string;
  status: string;
  company_id: string | null;
  sales_order_draft_id: string | null;
  accountable_team: string | null;
  accountable_owner_id: string | null;
  accountability_status: string;
  next_action: string | null;
  next_action_due_at: string | null;
  rule_version: string;
  closed_at: string | null;
};

export type WhatsAppCaseDecisionSnapshot = {
  packetId: string;
  communicationCase: WhatsAppCaseSnapshot | null;
  latestAi: Record<string, unknown> | null;
  identities: Record<string, unknown>[];
  recipientAuthorizations: Record<string, unknown>[];
  departmentTasks: Record<string, unknown>[];
  clarifications: Record<string, unknown>[];
  escalations: Record<string, unknown>[];
  outboundDecisions: Record<string, unknown>[];
  milestones: Record<string, unknown>[];
  closure: Record<string, unknown> | null;
  events: Record<string, unknown>[];
};

export type B2BCompanyCandidate = {
  id: string;
  business_name: string;
  phone: string | null;
  gst_number: string | null;
  status: string | null;
};

export type SalesOrderDraftCandidate = {
  id: string;
  status: string;
  company_id: string | null;
  company_name: string | null;
  readiness_overall_score: number | null;
  readiness_dimensions: Record<string, unknown> | null;
  promoted_order_id: string | null;
  created_at: string | null;
  updated_at: string | null;
};

export type CaseInboundMessage = {
  id: string;
  content: string | null;
  message_type: string | null;
  provider_message_id: string | null;
  packet_sequence: number | null;
  created_at: string | null;
  status: string | null;
};

export type AcceptAiRoutingInput = {
  caseId: string;
  accountableTeam: string;
  nextAction: string;
  dueAt: string;
  contributorDepartments: string[];
  idempotencyKey: string;
};

export type ConfirmCaseIdentityInput = {
  caseId: string;
  companyId: string;
  verificationMethod: "CRM_MATCH" | "GST_MATCH" | "CALLBACK" | "OPERATOR_VERIFIED" | "CUSTOMER_NOMINATED";
  disclosureScope: string[];
  mayReceiveClarification: boolean;
  mayConfirmCommercialScope: boolean;
  validUntil: string | null;
  identityEvidence: Record<string, unknown>;
  idempotencyKey: string;
};

const PACKET_AI_DEPARTMENT_SET = new Set<PacketAiDepartment>(PACKET_AI_DEPARTMENTS);
const DISCLOSURE_SCOPE_SET = new Set<string>(WHATSAPP_DISCLOSURE_SCOPES);

function record(value: unknown): Record<string, unknown> | null {
  return value != null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function records(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value)
    ? value.map(record).filter((item): item is Record<string, unknown> => item !== null)
    : [];
}

function text(value: unknown, max = 1000): string | null {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, max) : null;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function parseCase(value: unknown): WhatsAppCaseSnapshot | null {
  const item = record(value);
  if (!item) return null;
  const id = text(item.id, 80);
  const packetId = text(item.packet_id, 80);
  const caseType = text(item.case_type, 80);
  const status = text(item.status, 80);
  const accountabilityStatus = text(item.accountability_status, 80);
  const ruleVersion = text(item.rule_version, 160);
  if (!id || !packetId || !caseType || !status || !accountabilityStatus || !ruleVersion) return null;
  return {
    id,
    packet_id: packetId,
    case_type: caseType,
    status,
    company_id: text(item.company_id, 80),
    sales_order_draft_id: text(item.sales_order_draft_id, 80),
    accountable_team: text(item.accountable_team, 80),
    accountable_owner_id: text(item.accountable_owner_id, 80),
    accountability_status: accountabilityStatus,
    next_action: text(item.next_action, 1000),
    next_action_due_at: text(item.next_action_due_at, 120),
    rule_version: ruleVersion,
    closed_at: text(item.closed_at, 120),
  };
}

type RpcResult = { data: unknown; error: { message?: string } | null };
type RpcInvoker = (name: string, args?: Record<string, unknown>) => PromiseLike<RpcResult>;

function rpcInvoker(supabase: SupabaseClient): RpcInvoker {
  // Generated database types intentionally lag the forward-only companion Core PR.
  return supabase.rpc.bind(supabase) as unknown as RpcInvoker;
}

async function rpcRecord(supabase: SupabaseClient, name: string, args: Record<string, unknown>): Promise<Record<string, unknown>> {
  const { data, error } = await rpcInvoker(supabase)(name, args);
  if (error) throw new Error(error.message || `${name.toUpperCase()}_FAILED`);
  const result = record(data) ?? record(Array.isArray(data) ? data[0] : null);
  if (!result) throw new Error(`${name.toUpperCase()}_SHAPE_UNEXPECTED`);
  return result;
}

async function rpcRecords(supabase: SupabaseClient, name: string, args: Record<string, unknown>): Promise<Record<string, unknown>[]> {
  const { data, error } = await rpcInvoker(supabase)(name, args);
  if (error) throw new Error(error.message || `${name.toUpperCase()}_FAILED`);
  return records(data);
}

function required(value: string, code: string, max = 4000): string {
  const normalized = value.trim();
  if (!normalized || normalized.length > max) throw new Error(code);
  return normalized;
}

function futureIso(value: string, code: string): string {
  const normalized = required(value, code, 120);
  const epoch = Date.parse(normalized);
  if (!Number.isFinite(epoch) || epoch <= Date.now()) throw new Error(code);
  return new Date(epoch).toISOString();
}

function normalizedScopes(values: string[]): string[] {
  return [...new Set(values.map((value) => value.trim().toLowerCase()).filter((value) => DISCLOSURE_SCOPE_SET.has(value)))];
}

export async function fetchWhatsAppCaseDecisionSnapshot(
  supabase: SupabaseClient,
  packetId: string,
): Promise<WhatsAppCaseDecisionSnapshot> {
  const { data, error } = await rpcInvoker(supabase)("whatsapp_get_case_decision_snapshot", { p_packet_id: packetId });
  if (error) throw new Error(error.message || "CASE_SNAPSHOT_FAILED");
  const root = record(data) ?? record(Array.isArray(data) ? data[0] : null);
  if (!root) throw new Error("CASE_SNAPSHOT_SHAPE_UNEXPECTED");
  return {
    packetId,
    communicationCase: parseCase(root.case),
    latestAi: record(root.latest_ai),
    identities: records(root.identities),
    recipientAuthorizations: records(root.recipient_authorizations),
    departmentTasks: records(root.department_tasks),
    clarifications: records(root.clarifications),
    escalations: records(root.escalations),
    outboundDecisions: records(root.outbound_decisions),
    milestones: records(root.milestones),
    closure: record(root.closure),
    events: records(root.events),
  };
}

export async function acceptWhatsAppAiRouting(supabase: SupabaseClient, input: AcceptAiRoutingInput): Promise<Record<string, unknown>> {
  const team = required(input.accountableTeam, "CASE_ROUTING_TEAM_REQUIRED", 80).toUpperCase();
  const nextAction = required(input.nextAction, "CASE_ROUTING_ACTION_REQUIRED", 1000);
  const dueAt = futureIso(input.dueAt, "CASE_ROUTING_DUE_AT_INVALID");
  const idempotencyKey = required(input.idempotencyKey, "CASE_ROUTING_KEY_REQUIRED", 160);
  if (!input.caseId) throw new Error("CASE_ROUTING_CASE_REQUIRED");
  if (!PACKET_AI_DEPARTMENT_SET.has(team as PacketAiDepartment)) throw new Error("CASE_ROUTING_TEAM_INVALID");
  const contributors = [...new Set(input.contributorDepartments.map((d) => d.trim().toUpperCase()).filter((d) => PACKET_AI_DEPARTMENT_SET.has(d as PacketAiDepartment) && d !== team))].slice(0, 12);
  return rpcRecord(supabase, "whatsapp_accept_ai_case_routing", {
    p_case_id: input.caseId,p_accountable_team: team,p_next_action: nextAction,p_due_at: dueAt,
    p_contributor_departments: contributors,p_idempotency_key: idempotencyKey,
  });
}

export async function searchWhatsAppB2BCompanies(supabase: SupabaseClient, query: string): Promise<B2BCompanyCandidate[]> {
  const q = required(query, "COMPANY_SEARCH_REQUIRED", 100);
  if (q.length < 2) throw new Error("COMPANY_SEARCH_TOO_SHORT");
  const rows = await rpcRecords(supabase, "whatsapp_search_b2b_companies", { p_query: q,p_limit: 20 });
  return rows.map((item) => ({
    id: text(item.id, 80) ?? "",business_name: text(item.business_name, 300) ?? "Unnamed company",
    phone: text(item.phone, 80),gst_number: text(item.gst_number, 80),status: text(item.status, 80),
  })).filter((item) => item.id);
}

export async function confirmWhatsAppCaseIdentity(supabase: SupabaseClient, input: ConfirmCaseIdentityInput): Promise<Record<string, unknown>> {
  const scopes = normalizedScopes(input.disclosureScope);
  const validUntil = scopes.length > 0 ? futureIso(input.validUntil ?? "", "IDENTITY_AUTHORIZATION_EXPIRY_REQUIRED") : null;
  if (!input.caseId || !input.companyId) throw new Error("IDENTITY_CASE_AND_COMPANY_REQUIRED");
  if (!input.identityEvidence || Object.keys(input.identityEvidence).length === 0) throw new Error("IDENTITY_EVIDENCE_REQUIRED");
  return rpcRecord(supabase, "whatsapp_confirm_case_identity", {
    p_case_id: input.caseId,p_company_id: input.companyId,p_verification_method: input.verificationMethod,
    p_disclosure_scope: scopes,p_may_receive_clarification: input.mayReceiveClarification,
    p_may_confirm_commercial_scope: input.mayConfirmCommercialScope,p_valid_until: validUntil,
    p_identity_evidence: input.identityEvidence,p_idempotency_key: required(input.idempotencyKey,"IDENTITY_KEY_REQUIRED",160),
  });
}

export async function recordWhatsAppAiCaseDecision(supabase: SupabaseClient,input:{caseId:string;decision:"ACCEPT"|"MODIFY"|"REJECT";reason:string;caseType?:string|null;nextAction?:string|null;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  return rpcRecord(supabase,"whatsapp_record_ai_case_decision",{
    p_case_id:input.caseId,p_decision:input.decision,p_reason:required(input.reason,"AI_DECISION_REASON_REQUIRED",1000),
    p_case_type:input.caseType?.trim().toUpperCase()||null,p_next_action:input.nextAction?.trim()||null,
    p_idempotency_key:required(input.idempotencyKey,"AI_DECISION_KEY_REQUIRED",160),
  });
}

export async function askWhatsAppCustomer(supabase:SupabaseClient,input:{caseId:string;recipientAuthorizationId:string;fieldName:string;question:string;dueAt:string;disclosureScope:string[];idempotencyKey:string;}):Promise<Record<string, unknown>> {
  return rpcRecord(supabase,"whatsapp_ask_customer",{
    p_case_id:input.caseId,p_recipient_authorization_id:input.recipientAuthorizationId,
    p_field_name:required(input.fieldName,"CLARIFICATION_FIELD_REQUIRED",120).toUpperCase(),
    p_question:required(input.question,"CLARIFICATION_QUESTION_REQUIRED",4000),p_due_at:futureIso(input.dueAt,"CLARIFICATION_DUE_AT_INVALID"),
    p_disclosure_scope:normalizedScopes(input.disclosureScope),p_idempotency_key:required(input.idempotencyKey,"CLARIFICATION_KEY_REQUIRED",160),
  });
}

export async function releaseWhatsAppCaseReply(supabase:SupabaseClient,input:{caseId:string;recipientAuthorizationId:string;purpose:string;messageBody:string;disclosureScope:string[];relatedMilestoneEventId?:string|null;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  return rpcRecord(supabase,"whatsapp_release_case_reply",{
    p_case_id:input.caseId,p_recipient_authorization_id:input.recipientAuthorizationId,
    p_message_purpose:required(input.purpose,"CASE_REPLY_PURPOSE_REQUIRED",80).toUpperCase(),
    p_message_body:required(input.messageBody,"CASE_REPLY_BODY_REQUIRED",4000),p_disclosure_scope:normalizedScopes(input.disclosureScope),
    p_related_milestone_event_id:input.relatedMilestoneEventId||null,p_idempotency_key:required(input.idempotencyKey,"CASE_REPLY_KEY_REQUIRED",160),
  });
}

export async function completeWhatsAppCaseTask(supabase:SupabaseClient,input:{taskId:string;responsePayload:Record<string,unknown>;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  if (!input.taskId || !Object.keys(input.responsePayload).length) throw new Error("CASE_TASK_RESPONSE_REQUIRED");
  return rpcRecord(supabase,"whatsapp_complete_case_task",{p_task_id:input.taskId,p_response_payload:input.responsePayload,p_idempotency_key:required(input.idempotencyKey,"CASE_TASK_KEY_REQUIRED",160)});
}

export async function escalateWhatsAppCase(supabase:SupabaseClient,input:{caseId:string;level:number;reason:string;team:string;dueAt:string;departmentTaskId?:string|null;escalatedToUserId?:string|null;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  const team=input.team.trim().toUpperCase();
  if (!PACKET_AI_DEPARTMENT_SET.has(team as PacketAiDepartment)) throw new Error("CASE_ESCALATION_TEAM_INVALID");
  if (!Number.isInteger(input.level)||input.level<1||input.level>5) throw new Error("CASE_ESCALATION_LEVEL_INVALID");
  return rpcRecord(supabase,"whatsapp_escalate_case",{p_case_id:input.caseId,p_escalation_level:input.level,p_reason:required(input.reason,"CASE_ESCALATION_REASON_REQUIRED",1000),p_escalated_to_team:team,p_due_at:futureIso(input.dueAt,"CASE_ESCALATION_DUE_AT_INVALID"),p_department_task_id:input.departmentTaskId||null,p_escalated_to_user_id:input.escalatedToUserId||null,p_idempotency_key:required(input.idempotencyKey,"CASE_ESCALATION_KEY_REQUIRED",160)});
}

export async function resolveWhatsAppCaseEscalation(supabase:SupabaseClient,input:{escalationId:string;resolution:string;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  return rpcRecord(supabase,"whatsapp_resolve_case_escalation",{p_escalation_id:input.escalationId,p_resolution:required(input.resolution,"CASE_ESCALATION_RESOLUTION_REQUIRED",1000),p_idempotency_key:required(input.idempotencyKey,"CASE_ESCALATION_RESOLUTION_KEY_REQUIRED",160)});
}

export async function fetchWhatsAppCaseDraftCandidates(supabase:SupabaseClient,packetId:string):Promise<SalesOrderDraftCandidate[]> {
  const {data,error}=await rpcInvoker(supabase)("whatsapp_get_case_draft_candidates",{p_packet_id:packetId});
  if(error) throw new Error(error.message||"CASE_DRAFT_CANDIDATES_FAILED");
  return records(data).map((item)=>({id:text(item.id,80)??"",status:text(item.status,80)??"UNKNOWN",company_id:text(item.company_id,80),company_name:text(item.company_name,300),readiness_overall_score:numberOrNull(item.readiness_overall_score),readiness_dimensions:record(item.readiness_dimensions),promoted_order_id:text(item.promoted_order_id,80),created_at:text(item.created_at,120),updated_at:text(item.updated_at,120)})).filter((item)=>item.id);
}

export async function linkWhatsAppCaseSalesOrderDraft(supabase:SupabaseClient,input:{caseId:string;draftId:string;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  return rpcRecord(supabase,"whatsapp_link_case_sales_order_draft",{p_case_id:input.caseId,p_sales_order_draft_id:input.draftId,p_idempotency_key:required(input.idempotencyKey,"CASE_DRAFT_LINK_KEY_REQUIRED",160)});
}

export async function recordWhatsAppCaseMilestone(supabase:SupabaseClient,input:{caseId:string;milestoneType:string;customerRelevance:"SILENT"|"OPTIONAL"|"REQUIRED";facts:Record<string,unknown>;sourceEventKey:string;businessObjectType?:string|null;businessObjectId?:string|null;}):Promise<Record<string, unknown>> {
  return rpcRecord(supabase,"whatsapp_record_case_milestone",{p_case_id:input.caseId,p_milestone_type:input.milestoneType.trim().toUpperCase(),p_customer_relevance:input.customerRelevance,p_facts:input.facts,p_source_event_key:required(input.sourceEventKey,"MILESTONE_SOURCE_KEY_REQUIRED",200),p_business_object_type:input.businessObjectType?.trim()||null,p_business_object_id:input.businessObjectId||null});
}

export async function closeWhatsAppCase(supabase:SupabaseClient,input:{caseId:string;closureType:"RESOLVED"|"CANCELLED"|"DUPLICATE"|"NO_RESPONSE";resolutionSummary:string;unresolvedItems:unknown[];customerNotified:boolean;closureOutboundDecisionId?:string|null;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  return rpcRecord(supabase,"whatsapp_close_case",{p_case_id:input.caseId,p_closure_type:input.closureType,p_resolution_summary:required(input.resolutionSummary,"CASE_CLOSURE_SUMMARY_REQUIRED",2000),p_unresolved_items:input.unresolvedItems,p_customer_notified:input.customerNotified,p_closure_outbound_decision_id:input.closureOutboundDecisionId||null,p_idempotency_key:required(input.idempotencyKey,"CASE_CLOSURE_KEY_REQUIRED",160)});
}

export async function fetchWhatsAppCaseInboundMessages(supabase:SupabaseClient,packetId:string):Promise<CaseInboundMessage[]> {
  const {data,error}=await supabase.from("whatsapp_messages").select("id,content,message_type,provider_message_id,packet_sequence,created_at,status").eq("packet_id",packetId).eq("direction","inbound").order("packet_sequence",{ascending:true}).order("created_at",{ascending:true});
  if(error) throw new Error(error.message||"CASE_INBOUND_MESSAGES_FAILED");
  return (data??[]).map((item)=>({id:String(item.id),content:typeof item.content==="string"?item.content:null,message_type:typeof item.message_type==="string"?item.message_type:null,provider_message_id:typeof item.provider_message_id==="string"?item.provider_message_id:null,packet_sequence:typeof item.packet_sequence==="number"?item.packet_sequence:null,created_at:typeof item.created_at==="string"?item.created_at:null,status:typeof item.status==="string"?item.status:null}));
}

export async function confirmWhatsAppClarificationAnswer(supabase:SupabaseClient,input:{clarificationId:string;answerSourceMessageId:string;answerText:string;answerPayload:Record<string,unknown>;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  return rpcRecord(supabase,"whatsapp_confirm_clarification_answer",{p_clarification_id:input.clarificationId,p_answer_source_message_id:input.answerSourceMessageId,p_answer_text:required(input.answerText,"CLARIFICATION_ANSWER_REQUIRED",4000),p_answer_payload:input.answerPayload,p_idempotency_key:required(input.idempotencyKey,"CLARIFICATION_ANSWER_KEY_REQUIRED",160)});
}

export async function runWhatsAppShiftReconciliation(supabase:SupabaseClient,input:{windowStart:string;windowEnd:string;shiftCode:string;exceptionDueAt:string;idempotencyKey:string;}):Promise<Record<string, unknown>> {
  const start=new Date(required(input.windowStart,"RECONCILIATION_START_REQUIRED",120)); const end=new Date(required(input.windowEnd,"RECONCILIATION_END_REQUIRED",120));
  if(!Number.isFinite(start.getTime())||!Number.isFinite(end.getTime())||end<=start) throw new Error("RECONCILIATION_WINDOW_INVALID");
  return rpcRecord(supabase,"whatsapp_run_shift_reconciliation",{p_window_start:start.toISOString(),p_window_end:end.toISOString(),p_shift_code:required(input.shiftCode,"RECONCILIATION_SHIFT_REQUIRED",80),p_exception_due_at:futureIso(input.exceptionDueAt,"RECONCILIATION_EXCEPTION_DUE_INVALID"),p_idempotency_key:required(input.idempotencyKey,"RECONCILIATION_KEY_REQUIRED",160)});
}

export async function fetchWhatsAppReconciliationRun(supabase:SupabaseClient,runId:string):Promise<Record<string, unknown>> { return rpcRecord(supabase,"whatsapp_get_reconciliation_run",{p_run_id:runId}); }
export async function resolveWhatsAppReconciliationException(supabase:SupabaseClient,exceptionId:string,resolution:string):Promise<Record<string, unknown>> { return rpcRecord(supabase,"whatsapp_resolve_reconciliation_exception",{p_exception_id:exceptionId,p_resolution:required(resolution,"RECONCILIATION_RESOLUTION_REQUIRED",1000)}); }
export async function signoffWhatsAppReconciliation(supabase:SupabaseClient,runId:string):Promise<Record<string, unknown>> { return rpcRecord(supabase,"whatsapp_signoff_reconciliation",{p_run_id:runId}); }

export async function fetchWhatsAppCaseLearningCandidates(supabase:SupabaseClient,caseId:string):Promise<Record<string, unknown>[]> { const {data,error}=await rpcInvoker(supabase)("whatsapp_get_case_learning_candidates",{p_case_id:caseId}); if(error) throw new Error(error.message||"LEARNING_CANDIDATES_FAILED"); return records(data); }
export async function captureWhatsAppLearningCandidate(supabase:SupabaseClient,input:{caseId:string;sourceMessageId?:string|null;candidateType:string;observedValue:string;proposedMapping:Record<string,unknown>;evidence:Record<string,unknown>;idempotencyKey:string;}):Promise<Record<string, unknown>> { return rpcRecord(supabase,"whatsapp_capture_learning_candidate",{p_case_id:input.caseId,p_source_message_id:input.sourceMessageId||null,p_candidate_type:input.candidateType.trim().toUpperCase(),p_observed_value:required(input.observedValue,"LEARNING_OBSERVED_VALUE_REQUIRED",500),p_proposed_mapping:input.proposedMapping,p_evidence:input.evidence,p_idempotency_key:required(input.idempotencyKey,"LEARNING_KEY_REQUIRED",160)}); }
export async function reviewWhatsAppLearningCandidate(supabase:SupabaseClient,input:{candidateId:string;decision:"APPROVE_REFERENCE"|"REJECT"|"SUPERSEDE";reason:string;promotedObjectType?:string|null;promotedObjectId?:string|null;}):Promise<Record<string, unknown>> { return rpcRecord(supabase,"whatsapp_review_learning_candidate",{p_candidate_id:input.candidateId,p_decision:input.decision,p_reason:required(input.reason,"LEARNING_REVIEW_REASON_REQUIRED",1000),p_promoted_object_type:input.promotedObjectType?.trim()||null,p_promoted_object_id:input.promotedObjectId||null}); }

export async function fetchWhatsAppLegacyRetirements(supabase:SupabaseClient):Promise<Record<string, unknown>[]> { const {data,error}=await rpcInvoker(supabase)("whatsapp_get_legacy_retirements",{}); if(error) throw new Error(error.message||"LEGACY_RETIREMENTS_FAILED"); return records(data); }
export async function recordWhatsAppLegacyRetirement(supabase:SupabaseClient,input:{capabilityKey:string;legacySurface:string;disposition:string;canonicalDestination:string;evidence:Record<string,unknown>;}):Promise<Record<string, unknown>> { return rpcRecord(supabase,"whatsapp_record_legacy_retirement",{p_capability_key:required(input.capabilityKey,"RETIREMENT_CAPABILITY_REQUIRED",120),p_legacy_surface:required(input.legacySurface,"RETIREMENT_SURFACE_REQUIRED",500),p_disposition:input.disposition.trim().toUpperCase(),p_canonical_destination:required(input.canonicalDestination,"RETIREMENT_DESTINATION_REQUIRED",500),p_evidence:input.evidence}); }

export function newCaseActionIdempotencyKey(scope:string,entityId:string):string {
  const cryptoApi = globalThis.crypto;
  if (typeof cryptoApi?.randomUUID !== "function") {
    throw new Error("SECURE_RANDOM_UNAVAILABLE");
  }
  return `${scope}:${entityId}:${cryptoApi.randomUUID()}`.slice(0, 160);
}

export function newCaseRoutingIdempotencyKey(caseId:string):string { return newCaseActionIdempotencyKey("operator-ai-routing",caseId); }
