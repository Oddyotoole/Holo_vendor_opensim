//XEngine:
// $Id: mini vendor.lsl 20 2009-06-28 20:53:22Z jrn $
// Simplified vendor and self-destruct script. Designed to be driven from the
// holo vendor, it allows the rezzed prim to also act as a mini-vendor of itself,
// so the customer has a better chance of finding something to pay!
//
// WARNING: When removing an item, this doesn't move it to inventory, it DELETES
// the prim (and any prims it is linked to) PERMANENTLY. Be really careful not to
// put it in your only copy of an object.

string MSG_DIE = "xm:holo vendor:die";
string MSG_SELL = "xm:holo vendor:sell:";
string MSG_SPIN = "xm:holo vendor:spin:";

integer g_ListenChannel;
integer g_Price;
string g_VendName;

string getResidentURL(key id)
{
    return "secondlife:///app/agent/"
        + (string)id + "/about";
}

handleSpinMessage(string message)
{
    list parts;
            
    message = llGetSubString(message, llStringLength(MSG_SPIN), -1);
            
    parts = llParseString2List(message, [":"], []);
    if (llGetListLength(parts) != 3)
    {
        llInstantMessage(llGetOwner(), "Expected 3 parts to SPIN instruction, but found "
            + (string)llGetListLength(parts) + ".");
        return;
    }
            
    vector axis = (vector)llList2String(parts, 0);
    float spinRate = (float)llList2String(parts, 1);
    float gain = (float)llList2String(parts, 2);
            
    llTargetOmega(axis, spinRate, gain);
}

default
{
    // As a safety measure, this script won't enter the states where it can
    // delete, without a start param. This means it needs to either be
    // injected into a prim, or rezzed from a rezzer, to trigger.
    //
    // The holo vendor also stops this script when it starts, just in case.
    on_rez(integer startParam)
    {
        if (startParam != 0)
        {
            g_ListenChannel = startParam;
            state active;
        }
    }
}

state active
{
    changed(integer change)
    {
        if (change & CHANGED_OWNER)
        {
            llRemoveInventory(llGetScriptName());
            return;
        }
        
        if ((change & CHANGED_INVENTORY) == 0)
        {
            return;
        }
        
        if (g_VendName == "")
        {
            return;
        }
        
        // Check if an item we were waiting to ship, has arrived in inventory.
        if (llGetInventoryType(g_VendName) != INVENTORY_NONE)
        {
            if (llGetInventoryPermMask(g_VendName, MASK_OWNER) & PERM_TRANSFER)
            {
                state active_sale;
            }
    
            llInstantMessage(llGetOwner(), "The holo vendor has given me \""
                + g_VendName + "\" to sell, but you don't have transfer permissions on it!");
        }
    }
    
    listen(integer channel, string name, key id, string message)
    {        
        if (llGetOwner() != llGetOwnerKey(id))
        {
            return;
        }
        
        if (message == MSG_DIE)
        {
            llDie();
        }
        else if (llSubStringIndex(message, MSG_SELL) == 0)
        {
            integer colonIdx;
            
            message = llGetSubString(message, llStringLength(MSG_SELL), -1);
            colonIdx = llSubStringIndex(message, ":");
            
            if (colonIdx < 0)
            {
                llInstantMessage(llGetOwner(), "Expected : between price and object name in SELL instruction, but found \""
                    + message + "\".");
                return;
            }
            
            g_Price = (integer)llGetSubString(message, 0, colonIdx);
            g_VendName = (string)llGetSubString(message, colonIdx + 1, -1);
            
            if (g_Price < 0)
            {
                g_VendName = "";
                llInstantMessage(llGetOwner(), "Expected positive price in SELL instruction, but found "
                    + llGetSubString(message, 0, colonIdx) + ".");
                return;
            }
            
            // While chat commands should arrive before the item, you never know...
            if (llGetInventoryType(g_VendName) != INVENTORY_NONE)
            {
                if (llGetInventoryPermMask(g_VendName, MASK_OWNER) & PERM_TRANSFER)
                {
                    state active_sale;
                }
    
                llInstantMessage(llGetOwner(), "The holo vendor has given me \""
                    + g_VendName + "\" to sell, but you don't have transfer permissions on it!");
            }
        }
        else if (llSubStringIndex(message, MSG_SPIN) == 0)
        {
            handleSpinMessage(message);
        }
    }
    
    state_entry()
    {
        llListen(g_ListenChannel, "", NULL_KEY, "");
        g_Price = -1;
        g_VendName = "";
    }
}

state active_sale
{
    changed(integer change)
    {
        if (change & CHANGED_OWNER)
        {
            llRemoveInventory(llGetScriptName());
            return;
        }
        
        if ((change & CHANGED_INVENTORY) == 0)
        {
            return;
        }
        
        // Double check the owner hasn't just screwed up our inventory
        if (llGetInventoryType(g_VendName) == INVENTORY_NONE)
        {
            llShout(0, "Item for sale REMOVED. Committing suicide!");
            llDie();
            return;
        }
    }
    
    listen(integer channel, string name, key id, string message)
    {        
        if (llGetOwner() != llGetOwnerKey(id))
        {
            return;
        }
        
        if (message == MSG_DIE)
        {
            llDie();
        }
        else if (llSubStringIndex(message, MSG_SPIN) == 0)
        {
            handleSpinMessage(message);
        }
        
        // While it would be odd if we got a second sell command, it's not really
        // something there's anything we can do usefully to handle
    }
    
    state_entry()
    {
        llListen(g_ListenChannel, "", NULL_KEY, "");
        llSetPayPrice(PAY_HIDE, [g_Price, PAY_HIDE, PAY_HIDE, PAY_HIDE]);
    }
    
    money(key id, integer amount)
    {        
        if (g_Price != amount)
        {
            llInstantMessage(id, "You paid L$"
                + (string)amount + ", but the currently shown item \""
                + g_VendName + "\" costs L$"
                + (string)g_Price + ". Rejecting the transaction. You'll have to talk to my owner ( "
                    + getResidentURL(llGetOwner()) + " ) for a refund.");
            llInstantMessage(llGetOwner(), llKey2Name(id) + " ( "
                + getResidentURL(id) + " ) mis-paid L$"
                + (string)amount + " (expected L$"
                + (string)g_Price + ") to me, can you refund them please.");

            return;
        }
        
        // In case of any inventory changes we're meant to have re-loaded config, but just
        // in case we double check here. Still a race condition that the item could be deleted
        // after we check, and we don't get the change notification until after we leave
        // this event handler, but there's nothing I can do about that because LSL was
        // designed by someone with no idea of proper transactions. 
        if (llGetInventoryType(g_VendName) == INVENTORY_NONE)
        {
            llInstantMessage(id, "Unfortunately the item for delivery is missing from my inventory! Rejecting the transaction. I do not have debit permissions, so you'll have to talk to my owner ( "
                + getResidentURL(llGetOwner()) + " ) for a refund.");
            llInstantMessage(llGetOwner(), llKey2Name(id) + " just tried buying \""
                + g_VendName + "\" but it's missing from my inventory. Can you refund them L$"
                + (string)amount + " please.");
        }
        
        llGiveInventory(id, g_VendName);
    }
}
