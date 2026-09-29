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

export type BoundedRetryAttemptContext = {
  signal: AbortSignal;
  deadlineMs?: number;
  remainingBudgetMs?: number;
};

export type ExecuteWithBoundedRetryOptions<T> = {
  policy: BoundedRetryPolicy;
  operation: (
    attempt: number,
    context: BoundedRetryAttemptContext,
  ) => Promise<T>;
  isRetryable?: (error: unknown) => boolean;
  sleep?: (milliseconds: number) => Promise<void>;
  now?: () => number;
};

const budgetExceeded = (): IntegrationError =>
  new IntegrationError("INTEGRATION_RETRY_BUDGET_EXCEEDED", "permanent");

const validatePolicy = (policy: BoundedRetryPolicy): void => {
  if (
    !Number.isFinite(policy.maxAttempts) ||
    !Number.isInteger(policy.maxAttempts) ||
    policy.maxAttempts < 1
  ) {
    throw new IntegrationError("RETRY_POLICY_INVALID", "permanent");
  }
  if (
    policy.totalBudgetMs !== undefined &&
    (!Number.isFinite(policy.totalBudgetMs) || policy.totalBudgetMs <= 0)
  ) {
    throw new IntegrationError("RETRY_POLICY_INVALID", "permanent");
  }
  if (
    policy.retryDelaysMs.some((delay) => !Number.isFinite(delay) || delay < 0)
  ) {
    throw new IntegrationError("RETRY_POLICY_INVALID", "permanent");
  }
};

/**
 * Executes an integration call with bounded attempts, explicit retry classification,
 * and an optional total budget. Permanent failures fail closed immediately.
 *
 * When a total budget is configured, each operation receives an AbortSignal and
 * absolute deadline. The executor races the operation against the remaining
 * budget so a hung operation cannot make the retry loop unbounded.
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

  validatePolicy(policy);

  const startedAt = now();
  const deadlineMs = policy.totalBudgetMs === undefined
    ? undefined
    : startedAt + policy.totalBudgetMs;
  let lastRetryableError: unknown = null;

  for (let attempt = 0; attempt < policy.maxAttempts; attempt += 1) {
    const remainingBudgetMs = deadlineMs === undefined
      ? undefined
      : deadlineMs - now();

    if (remainingBudgetMs !== undefined && remainingBudgetMs <= 0) {
      if (lastRetryableError instanceof IntegrationError) {
        throw lastRetryableError;
      }
      throw budgetExceeded();
    }

    const controller = new AbortController();
    const context: BoundedRetryAttemptContext = {
      signal: controller.signal,
      deadlineMs,
      remainingBudgetMs,
    };

    try {
      const operationPromise = operation(attempt, context);
      let value: T;

      if (remainingBudgetMs === undefined) {
        value = await operationPromise;
      } else {
        let timeoutId: number | undefined;
        const timeoutPromise = new Promise<never>((_resolve, reject) => {
          timeoutId = setTimeout(() => {
            reject(budgetExceeded());
            controller.abort();
          }, remainingBudgetMs);
        });
        try {
          value = await Promise.race([operationPromise, timeoutPromise]);
        } finally {
          if (timeoutId !== undefined) clearTimeout(timeoutId);
        }

        if (now() >= (deadlineMs as number)) {
          controller.abort();
          throw budgetExceeded();
        }
      }

      return value;
    } catch (error) {
      controller.abort();

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
        deadlineMs !== undefined &&
        now() + delayMs >= deadlineMs
      ) {
        throw error instanceof Error
          ? error
          : budgetExceeded();
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
