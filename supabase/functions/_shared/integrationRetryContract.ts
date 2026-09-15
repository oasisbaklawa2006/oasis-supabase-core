/** @file Shared integration retry/error contract for Core Edge boundaries. */

export type IntegrationRetryDisposition = "retryable" | "permanent";

export type BoundedRetryPolicy = {
  maxAttempts: number;
  retryDelaysMs: readonly number[];
  totalBudgetMs?: number;
};

export class IntegrationError extends Error {
  readonly code: string;
  readonly disposition: IntegrationRetryDisposition;

  constructor(
    code: string,
    disposition: IntegrationRetryDisposition,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "IntegrationError";
    this.code = code;
    this.disposition = disposition;
  }
}

/** HTTP statuses safe to retry without changing commercial authority. */
export function isTransientHttpStatus(status: number): boolean {
  return status === 408 || status === 429 || (status >= 500 && status <= 599);
}

export function classifyHttpStatus(status: number): IntegrationRetryDisposition {
  return isTransientHttpStatus(status) ? "retryable" : "permanent";
}

export function isRetryableIntegrationError(error: unknown): boolean {
  if (error instanceof IntegrationError) {
    return error.disposition === "retryable";
  }
  return false;
}

const defaultSleep = (milliseconds: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

export type ExecuteWithBoundedRetryOptions<T> = {
  policy: BoundedRetryPolicy;
  operation: (attempt: number) => Promise<T>;
  isRetryable?: (error: unknown) => boolean;
  sleep?: (milliseconds: number) => Promise<void>;
  now?: () => number;
};

/**
 * Executes an integration call with bounded attempts, explicit retry classification,
 * and an optional total budget. Permanent failures fail closed immediately.
 */
export async function executeWithBoundedRetry<T>(
  options: ExecuteWithBoundedRetryOptions<T>,
): Promise<T> {
  const {
    policy,
    operation,
    isRetryable = isRetryableIntegrationError,
    sleep = defaultSleep,
    now = Date.now,
  } = options;

  if (policy.maxAttempts < 1) {
    throw new IntegrationError("RETRY_POLICY_INVALID", "permanent");
  }

  const startedAt = now();
  let lastRetryableError: unknown = null;

  for (let attempt = 0; attempt < policy.maxAttempts; attempt += 1) {
    if (
      policy.totalBudgetMs !== undefined &&
      now() - startedAt >= policy.totalBudgetMs
    ) {
      if (lastRetryableError instanceof IntegrationError) {
        throw lastRetryableError;
      }
      throw new IntegrationError("INTEGRATION_RETRY_BUDGET_EXCEEDED", "permanent");
    }

    try {
      return await operation(attempt);
    } catch (error) {
      if (!isRetryable(error)) {
        throw error instanceof Error
          ? error
          : new IntegrationError("INTEGRATION_PERMANENT_FAILURE", "permanent");
      }

      lastRetryableError = error;

      if (attempt >= policy.maxAttempts - 1) {
        throw error instanceof Error
          ? error
          : new IntegrationError("INTEGRATION_RETRY_EXHAUSTED", "permanent");
      }

      const delayMs = policy.retryDelaysMs[attempt] ??
        policy.retryDelaysMs[policy.retryDelaysMs.length - 1] ??
        0;

      if (
        policy.totalBudgetMs !== undefined &&
        now() - startedAt + delayMs >= policy.totalBudgetMs
      ) {
        throw error instanceof Error
          ? error
          : new IntegrationError("INTEGRATION_RETRY_BUDGET_EXCEEDED", "permanent");
      }

      if (delayMs > 0) {
        await sleep(delayMs);
      }
    }
  }

  throw lastRetryableError instanceof Error
    ? lastRetryableError
    : new IntegrationError("INTEGRATION_RETRY_EXHAUSTED", "permanent");
}
