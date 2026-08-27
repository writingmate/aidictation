export const TIER_SEATS: Record<number, number> = { 1: 1, 2: 4, 3: 5 };

export const tierToSeats = (tier: number): number => TIER_SEATS[tier] ?? 1;
