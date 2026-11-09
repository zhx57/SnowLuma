import { describe, expect, it, vi } from 'vitest';
import type { SendPacketResult } from '@snowluma/common/packet-sender';

import { SetMemberCard } from '../../../src/oidb-services/group-admin/set-member-card';
import { env, m, s, v } from '../_pb-oracle';

function makeDeps() {
    const r: SendPacketResult = {
        success: true,
        gotResponse: true,
        errorCode: 0,
        errorMessage: '',
        responseData: Buffer.alloc(0),
    };
    return {
        sendRawPacket: vi.fn<SetMemberCard.Deps['sendRawPacket']>().mockResolvedValue(r),
        resolveUserUid: vi.fn(async () => 'resolved-uid'),
    };
}

describe('SetMemberCard namespace', () => {
    it('declares 0x8FC_3', () => {
        expect(SetMemberCard.command).toBe(0x8fc);
        expect(SetMemberCard.subCommand).toBe(3);
    });

    it.each(['', 'newCard', '群名片'])('sends card %j in field 8', async (card) => {
        const deps = makeDeps();
        await SetMemberCard.invoke(deps, { groupId: 12345, userId: 67890, card });
        expect(deps.resolveUserUid).toHaveBeenCalledWith(67890, 12345);
        const [wire, bytes] = deps.sendRawPacket.mock.calls[0]!;
        expect(wire).toBe('OidbSvcTrpcTcp.0x8fc_3');

        const member = [...s(1, 'resolved-uid'), ...s(8, card)];
        const body = [...v(1, 12345), ...m(3, member)];
        expect(Buffer.from(bytes).toString('hex')).toBe(env(0x8fc, 3, body, false));
    });
});
