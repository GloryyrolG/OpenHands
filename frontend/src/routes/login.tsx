import React from "react";
import { useNavigate, useSearchParams } from "react-router";
import { useTranslation } from "react-i18next";
import { EmailAuthForm } from "#/components/features/auth/email-auth-form";
import { useAuth } from "#/hooks/use-auth";
import { I18nKey } from "#/i18n/declaration";

export default function LoginPage() {
  const { t } = useTranslation();
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const returnTo = searchParams.get("returnTo") || "/";

  const { isAuthenticated, isLoading: authLoading, user } = useAuth();

  // Redirect ONLY if authenticated with valid token
  React.useEffect(() => {
    if (!authLoading && isAuthenticated && user) {
      navigate(returnTo, { replace: true });
    }
  }, [isAuthenticated, authLoading, user, navigate, returnTo]);

  if (authLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gray-900">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-white" />
      </div>
    );
  }

  // If already authenticated, don't show login form (will redirect)
  if (isAuthenticated && user) {
    return null;
  }

  // Show login form
  return (
    <div className="min-h-screen flex items-center justify-center bg-gray-900 p-4">
      <div className="text-center mb-8">
        <h1 className="text-3xl font-bold text-white mb-2">
          {t(I18nKey.BRANDING$OPENHANDS)}
        </h1>
        {/* eslint-disable-next-line i18next/no-literal-string */}
        <p className="text-gray-400">Sign in to continue</p>
      </div>
      <EmailAuthForm />
    </div>
  );
}
