-- Who: the /who fallback of Inn hop (D20) for hosts without Portaxi. Game glue.
-- Contract: docs/PORTAXI_MVP_PLAYBOOK.md §2 "Inn hop (D20)". Empty until step 4 of docs/INN_HOP_PLAN.md §8;
-- listed in the TOC now so the later code needs no client restart (D7).

local _, ns = ...

ns.Who = ns.Who or {}
