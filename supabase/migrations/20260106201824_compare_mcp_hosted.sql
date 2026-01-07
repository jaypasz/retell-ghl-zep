
  create table "public"."appointments" (
    "id" uuid not null default extensions.uuid_generate_v4(),
    "contact_id" uuid,
    "call_id" uuid,
    "ghl_appointment_id" text,
    "scheduled_at" timestamp with time zone not null,
    "status" text not null default 'scheduled'::text,
    "reminder_sent" boolean default false,
    "notes" text,
    "created_at" timestamp with time zone default now(),
    "updated_at" timestamp with time zone default now()
      );



  create table "public"."cache_entries" (
    "key" text not null,
    "value" jsonb not null,
    "expires_at" timestamp with time zone not null,
    "created_at" timestamp with time zone default now()
      );



  create table "public"."call_logs" (
    "id" uuid not null default extensions.uuid_generate_v4(),
    "call_id" text not null,
    "phone_number" text not null,
    "call_started_at" timestamp with time zone not null,
    "call_ended_at" timestamp with time zone,
    "duration_seconds" integer,
    "outcome" text,
    "transcript" jsonb,
    "metadata" jsonb,
    "created_at" timestamp with time zone default now(),
    "updated_at" timestamp with time zone default now()
      );



  create table "public"."contacts" (
    "id" uuid not null default extensions.uuid_generate_v4(),
    "phone_number" text not null,
    "name" text,
    "email" text,
    "company" text,
    "ghl_contact_id" text,
    "zep_session_id" text,
    "tags" text[],
    "custom_fields" jsonb,
    "last_call_at" timestamp with time zone,
    "total_calls" integer default 0,
    "created_at" timestamp with time zone default now(),
    "updated_at" timestamp with time zone default now()
      );



  create table "public"."daily_metrics" (
    "id" uuid not null default extensions.uuid_generate_v4(),
    "date" date not null,
    "total_calls" integer default 0,
    "appointments_booked" integer default 0,
    "transfers" integer default 0,
    "avg_call_duration" numeric(10,2),
    "conversion_rate" numeric(5,2),
    "metadata" jsonb,
    "created_at" timestamp with time zone default now(),
    "updated_at" timestamp with time zone default now()
      );


CREATE UNIQUE INDEX appointments_pkey ON public.appointments USING btree (id);

CREATE UNIQUE INDEX cache_entries_pkey ON public.cache_entries USING btree (key);

CREATE UNIQUE INDEX call_logs_call_id_key ON public.call_logs USING btree (call_id);

CREATE UNIQUE INDEX call_logs_pkey ON public.call_logs USING btree (id);

CREATE UNIQUE INDEX contacts_phone_number_key ON public.contacts USING btree (phone_number);

CREATE UNIQUE INDEX contacts_pkey ON public.contacts USING btree (id);

CREATE UNIQUE INDEX daily_metrics_date_key ON public.daily_metrics USING btree (date);

CREATE UNIQUE INDEX daily_metrics_pkey ON public.daily_metrics USING btree (id);

CREATE INDEX idx_appointments_contact ON public.appointments USING btree (contact_id);

CREATE INDEX idx_appointments_ghl_id ON public.appointments USING btree (ghl_appointment_id);

CREATE INDEX idx_appointments_scheduled ON public.appointments USING btree (scheduled_at);

CREATE INDEX idx_appointments_status ON public.appointments USING btree (status);

CREATE INDEX idx_cache_expires ON public.cache_entries USING btree (expires_at);

CREATE INDEX idx_call_logs_outcome ON public.call_logs USING btree (outcome);

CREATE INDEX idx_call_logs_phone ON public.call_logs USING btree (phone_number);

CREATE INDEX idx_call_logs_started ON public.call_logs USING btree (call_started_at DESC);

CREATE INDEX idx_contacts_ghl_id ON public.contacts USING btree (ghl_contact_id);

CREATE INDEX idx_contacts_last_call ON public.contacts USING btree (last_call_at DESC);

CREATE INDEX idx_contacts_phone ON public.contacts USING btree (phone_number);

CREATE INDEX idx_daily_metrics_date ON public.daily_metrics USING btree (date DESC);

alter table "public"."appointments" add constraint "appointments_pkey" PRIMARY KEY using index "appointments_pkey";

alter table "public"."cache_entries" add constraint "cache_entries_pkey" PRIMARY KEY using index "cache_entries_pkey";

alter table "public"."call_logs" add constraint "call_logs_pkey" PRIMARY KEY using index "call_logs_pkey";

alter table "public"."contacts" add constraint "contacts_pkey" PRIMARY KEY using index "contacts_pkey";

alter table "public"."daily_metrics" add constraint "daily_metrics_pkey" PRIMARY KEY using index "daily_metrics_pkey";

alter table "public"."appointments" add constraint "appointments_call_id_fkey" FOREIGN KEY (call_id) REFERENCES public.call_logs(id) ON DELETE SET NULL not valid;

alter table "public"."appointments" validate constraint "appointments_call_id_fkey";

alter table "public"."appointments" add constraint "appointments_contact_id_fkey" FOREIGN KEY (contact_id) REFERENCES public.contacts(id) ON DELETE CASCADE not valid;

alter table "public"."appointments" validate constraint "appointments_contact_id_fkey";

alter table "public"."call_logs" add constraint "call_logs_call_id_key" UNIQUE using index "call_logs_call_id_key";

alter table "public"."contacts" add constraint "contacts_phone_number_key" UNIQUE using index "contacts_phone_number_key";

alter table "public"."daily_metrics" add constraint "daily_metrics_date_key" UNIQUE using index "daily_metrics_date_key";

set check_function_bodies = off;

create or replace view "public"."appointment_summary" as  SELECT a.id,
    c.phone_number,
    c.name AS customer_name,
    a.scheduled_at,
    a.status,
    a.ghl_appointment_id,
    cl.call_id
   FROM ((public.appointments a
     JOIN public.contacts c ON ((a.contact_id = c.id)))
     LEFT JOIN public.call_logs cl ON ((a.call_id = cl.id)))
  ORDER BY a.scheduled_at DESC;


create or replace view "public"."conversion_metrics" as  SELECT date,
    total_calls,
    appointments_booked,
    conversion_rate,
    avg_call_duration
   FROM public.daily_metrics
  ORDER BY date DESC;


CREATE OR REPLACE FUNCTION public.delete_expired_cache()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  DELETE FROM cache_entries WHERE expires_at < NOW();
END;
$function$
;

create or replace view "public"."recent_calls" as  SELECT cl.call_id,
    cl.phone_number,
    c.name AS customer_name,
    cl.call_started_at,
    cl.call_ended_at,
    cl.duration_seconds,
    cl.outcome,
    c.total_calls
   FROM (public.call_logs cl
     LEFT JOIN public.contacts c ON ((cl.phone_number = c.phone_number)))
  ORDER BY cl.call_started_at DESC;


CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$function$
;

grant delete on table "public"."appointments" to "anon";

grant insert on table "public"."appointments" to "anon";

grant references on table "public"."appointments" to "anon";

grant select on table "public"."appointments" to "anon";

grant trigger on table "public"."appointments" to "anon";

grant truncate on table "public"."appointments" to "anon";

grant update on table "public"."appointments" to "anon";

grant delete on table "public"."appointments" to "authenticated";

grant insert on table "public"."appointments" to "authenticated";

grant references on table "public"."appointments" to "authenticated";

grant select on table "public"."appointments" to "authenticated";

grant trigger on table "public"."appointments" to "authenticated";

grant truncate on table "public"."appointments" to "authenticated";

grant update on table "public"."appointments" to "authenticated";

grant delete on table "public"."appointments" to "service_role";

grant insert on table "public"."appointments" to "service_role";

grant references on table "public"."appointments" to "service_role";

grant select on table "public"."appointments" to "service_role";

grant trigger on table "public"."appointments" to "service_role";

grant truncate on table "public"."appointments" to "service_role";

grant update on table "public"."appointments" to "service_role";

grant delete on table "public"."cache_entries" to "anon";

grant insert on table "public"."cache_entries" to "anon";

grant references on table "public"."cache_entries" to "anon";

grant select on table "public"."cache_entries" to "anon";

grant trigger on table "public"."cache_entries" to "anon";

grant truncate on table "public"."cache_entries" to "anon";

grant update on table "public"."cache_entries" to "anon";

grant delete on table "public"."cache_entries" to "authenticated";

grant insert on table "public"."cache_entries" to "authenticated";

grant references on table "public"."cache_entries" to "authenticated";

grant select on table "public"."cache_entries" to "authenticated";

grant trigger on table "public"."cache_entries" to "authenticated";

grant truncate on table "public"."cache_entries" to "authenticated";

grant update on table "public"."cache_entries" to "authenticated";

grant delete on table "public"."cache_entries" to "service_role";

grant insert on table "public"."cache_entries" to "service_role";

grant references on table "public"."cache_entries" to "service_role";

grant select on table "public"."cache_entries" to "service_role";

grant trigger on table "public"."cache_entries" to "service_role";

grant truncate on table "public"."cache_entries" to "service_role";

grant update on table "public"."cache_entries" to "service_role";

grant delete on table "public"."call_logs" to "anon";

grant insert on table "public"."call_logs" to "anon";

grant references on table "public"."call_logs" to "anon";

grant select on table "public"."call_logs" to "anon";

grant trigger on table "public"."call_logs" to "anon";

grant truncate on table "public"."call_logs" to "anon";

grant update on table "public"."call_logs" to "anon";

grant delete on table "public"."call_logs" to "authenticated";

grant insert on table "public"."call_logs" to "authenticated";

grant references on table "public"."call_logs" to "authenticated";

grant select on table "public"."call_logs" to "authenticated";

grant trigger on table "public"."call_logs" to "authenticated";

grant truncate on table "public"."call_logs" to "authenticated";

grant update on table "public"."call_logs" to "authenticated";

grant delete on table "public"."call_logs" to "service_role";

grant insert on table "public"."call_logs" to "service_role";

grant references on table "public"."call_logs" to "service_role";

grant select on table "public"."call_logs" to "service_role";

grant trigger on table "public"."call_logs" to "service_role";

grant truncate on table "public"."call_logs" to "service_role";

grant update on table "public"."call_logs" to "service_role";

grant delete on table "public"."contacts" to "anon";

grant insert on table "public"."contacts" to "anon";

grant references on table "public"."contacts" to "anon";

grant select on table "public"."contacts" to "anon";

grant trigger on table "public"."contacts" to "anon";

grant truncate on table "public"."contacts" to "anon";

grant update on table "public"."contacts" to "anon";

grant delete on table "public"."contacts" to "authenticated";

grant insert on table "public"."contacts" to "authenticated";

grant references on table "public"."contacts" to "authenticated";

grant select on table "public"."contacts" to "authenticated";

grant trigger on table "public"."contacts" to "authenticated";

grant truncate on table "public"."contacts" to "authenticated";

grant update on table "public"."contacts" to "authenticated";

grant delete on table "public"."contacts" to "service_role";

grant insert on table "public"."contacts" to "service_role";

grant references on table "public"."contacts" to "service_role";

grant select on table "public"."contacts" to "service_role";

grant trigger on table "public"."contacts" to "service_role";

grant truncate on table "public"."contacts" to "service_role";

grant update on table "public"."contacts" to "service_role";

grant delete on table "public"."daily_metrics" to "anon";

grant insert on table "public"."daily_metrics" to "anon";

grant references on table "public"."daily_metrics" to "anon";

grant select on table "public"."daily_metrics" to "anon";

grant trigger on table "public"."daily_metrics" to "anon";

grant truncate on table "public"."daily_metrics" to "anon";

grant update on table "public"."daily_metrics" to "anon";

grant delete on table "public"."daily_metrics" to "authenticated";

grant insert on table "public"."daily_metrics" to "authenticated";

grant references on table "public"."daily_metrics" to "authenticated";

grant select on table "public"."daily_metrics" to "authenticated";

grant trigger on table "public"."daily_metrics" to "authenticated";

grant truncate on table "public"."daily_metrics" to "authenticated";

grant update on table "public"."daily_metrics" to "authenticated";

grant delete on table "public"."daily_metrics" to "service_role";

grant insert on table "public"."daily_metrics" to "service_role";

grant references on table "public"."daily_metrics" to "service_role";

grant select on table "public"."daily_metrics" to "service_role";

grant trigger on table "public"."daily_metrics" to "service_role";

grant truncate on table "public"."daily_metrics" to "service_role";

grant update on table "public"."daily_metrics" to "service_role";

CREATE TRIGGER update_appointments_updated_at BEFORE UPDATE ON public.appointments FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_call_logs_updated_at BEFORE UPDATE ON public.call_logs FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_contacts_updated_at BEFORE UPDATE ON public.contacts FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_daily_metrics_updated_at BEFORE UPDATE ON public.daily_metrics FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


