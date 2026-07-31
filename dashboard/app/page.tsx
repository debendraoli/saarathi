"use client";

import { auth } from "@/lib/api";
import { useRouter } from "next/navigation";
import { useEffect } from "react";

export default function Home() {
  const router = useRouter();
  useEffect(() => {
    router.replace(auth.access ? "/drivers" : "/login");
  }, [router]);
  return null;
}
