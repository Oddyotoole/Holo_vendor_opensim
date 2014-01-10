//XEngine:
// $Id: holo vendor.lsl 47 2009-08-09 16:47:49Z jrn $
// Holo (rezzing) vendor, to show a variety of products for sale without
// requiring individual vendors for each.
//
// Rezzed objects MUST have the matching "Die" script in them, so this script
// can trigger them derezzing. As such, each object needs to have two version;
// the rezzed version, and the version for sale. Associating these is done in
// the configuration notecard (see instructions for details).

// Constants
string BUTTON_NEXT = "[Next]";
string BUTTON_PREV = "[Prev]";

string CONFIGURATION_NOTECARD_NAME = "Configuration";
string LINDEN_DOLLAR = "L$";

integer MAX_BUTTON_LENGTH = 24;
integer MAX_DIALOG_BUTTONS = 12;
integer OBJECTS_PER_DIALOG = 10; // (MAX_DIALOG_BUTTONS after next and previous buttons added).

string MSG_DIE = "xm:holo vendor:die";
string MSG_SELL = "xm:holo vendor:sell:";
string MSG_SPIN = "xm:holo vendor:spin:";

// User configurable values (read in from the notecard)

// Whether the rezzer should use auto-display mode (TRUE) or not (FALSE).
integer g_AutoCycleEnabled = FALSE;

// Time between rezzing a new item, when running in auto mode. Also
// the interval in which to scan for nearby avatars when inactive.
float g_AutoCycleTime = 30.0; // Seconds

string g_BaseName = "holo vendor";

vector g_DefaultOffset = ZERO_VECTOR;
integer g_DefaultPrice = -1;
rotation g_DefaultRotation = ZERO_ROTATION;

float g_InactivityDelay = 30.0; // Seconds

// Range at which to scan for inactivity
float g_ScanRange = 20.0; // Metres

// Spin rate to apply to shown items, in radians per second.
float g_SpinRate = 0.0;

// Synchronized lists of the names, rez offets, prices and name of object to
// deliver for each product.
list g_ProductDisplayNames;
list g_ProductDisplayOffsets;
list g_ProductPrices;
list g_ProductContents;

// Whether the vendor should be silent, or should say object details (name & price).
integer g_Silent = FALSE;

// Whether the vendor should whisper or say object details.
integer g_Whisper = TRUE;

// These hold the current state

integer g_ConfiguringItem;

// Synchronized lists of the names, rez offets, prices and name of object to
// deliver for each product.
string g_CurrentDisplayName;
vector g_CurrentDisplayOffset;
integer g_CurrentPrice;
string g_CurrentContent;

key g_ActiveUserKey = NULL_KEY;
// The time at which we last had communication with the active user. Used
// to allow the control to be taken after g_InactivityDelay seconds.
integer g_ActiveUserTime;

list g_Buttons;
list g_ButtonsWithClear;

integer g_DialogChannel;
integer g_ListenHandle;

// Used both for initial configuration, and tracking where the active user
// in the list of possible objects.
integer g_ItemIdx;

integer g_NotecardLine;
key g_NotecardQuery;

// Whether one time startup actions have been done. Used by the default
// state
integer g_OneTimeSetupPerformed = FALSE;

// The channel on which to communicate with the rezzed object
integer g_RezChannel;

// Generates a URL that can be clicked to bring up an avatar profile
string getResidentURL(key id)
{
    return "secondlife:///app/agent/"
        + (string)id + "/about";
}

handleSale(key id, integer amount)
{    
    if (g_CurrentPrice != amount)
    {
        llInstantMessage(id, "You paid L$"
            + (string)amount + ", but the currently shown item \""
            + g_CurrentDisplayName + "\" costs L$"
            + (string)g_CurrentPrice + ". Rejecting the transaction.");
                
        if (llGetPermissions() & PERMISSION_DEBIT)
        {
            llGiveMoney(id, amount);
        }
        else
        {
            llInstantMessage(id, "I do not have debit permissions, so you'll have to talk to my owner ( "
                + getResidentURL(llGetOwner()) + " ) for a refund.");
            llInstantMessage(llGetOwner(), llKey2Name(id) + " ( "
                + getResidentURL(id) + " ) mis-paid L$"
                + (string)amount + " (expected L$"
                + (string)g_CurrentPrice + ") to me, can you refund them please.");
        }
        
        return;
    }
    
    // In case of any inventory changes we're meant to have re-loaded config, but just
    // in case we double check here. Still a race condition that the item could be deleted
    // after we check, and we don't get the change notification until after we leave
    // this event handler, but there's nothing I can do about that because LSL was
    // designed by someone with no idea of proper transactions. 
    if (llGetInventoryType(g_CurrentContent) == INVENTORY_NONE)
    {
        llInstantMessage(id, "Unfortunately that item is missing from my inventory! Rejecting the transaction.");
                
        if (llGetPermissions() & PERMISSION_DEBIT)
        {
            llInstantMessage(llGetOwner(), llKey2Name(id) + " just tried buying \""
                + g_CurrentContent + "\" but it's missing from my inventory. I'm going to refund them, but please fix me!");
            llGiveMoney(id, amount);
        }
        else
        {
            // XXX: Should give out co-ordinates
            llInstantMessage(id, "I do not have debit permissions, so you'll have to talk to my owner ( "
                + getResidentURL(llGetOwner()) + " ) for a refund.");
            llInstantMessage(llGetOwner(), llKey2Name(id) + " just tried buying \""
                + g_CurrentContent + "\" but it's missing from my inventory. Can you refund them L$"
                + (string)amount + " please.");
        }
            
        state default;
    }
    
    llGiveInventory(id, g_CurrentContent);
}

// Takes in a line of text from the configuration notecard and parses it. In
// the case of a new section start ("[default]" or "[item]"), it validates the
// section ending, and then returns. Otherwise it breaks the input down into
// two parts around the "=" character; the first part is the name, the second
// its value.
//
// Returns TRUE on success, FALSE otherwise.
integer parseConfigurationLine(string data) {    
    data = llStringTrim(data, STRING_TRIM);
    if (data == "" ||
        llGetSubString(data, 0, 0) == "#") {
        // Comment, ignore
        return TRUE;
    }
    
    if (data == "[default]")
    {
        // We ignore this; it used to tell the script the defaults were being
        // configured, now it just assumes that if it's not mid-item.
    }
    else if (data == "[item]")
    {
        if (g_ConfiguringItem)
        {
            if (!validateAndAddItem())
            {
                return FALSE;
            }
        }
        else
        {
            g_ConfiguringItem = TRUE;
        }
        
        g_ItemIdx++;
        g_CurrentDisplayName = "";
        g_CurrentDisplayOffset = g_DefaultOffset;
        g_CurrentPrice = g_DefaultPrice;
        g_CurrentContent = "";
    }
    else
    {
        string name;
        string value;
        list parts = llParseString2List(data, ["="], []);
        
        if (llGetListLength(parts) != 2) {
            llOwnerSay("Configuration notecard line \""
                + data + "\" (from \""
                + CONFIGURATION_NOTECARD_NAME+ "\") could not be parsed.");
            return FALSE;
        }
    
        name = llToLower(llStringTrim(llList2String(parts, 0), STRING_TRIM));
        value = llStringTrim(llList2String(parts, 1), STRING_TRIM);
        
        if (g_ConfiguringItem)
        {
            return parseItemConfiguration(name, value);
        }
        else
        {
            return parseDefaultConfiguration(name, value);
        }
    }
    
    return TRUE;
}

// Handles most options that the can come from the configuration notecard. Does
// not deal with item setup directly, instead passing them to the
// processItemConfiguration() method.
//
// name is converted to lower case before calling this function, but value IS NOT,
// so needs to be converted if you wish to do case insensitive comparisons.
// Returns TRUE on success, FALSE otherwise.
integer parseDefaultConfiguration(string name, string value)
{
    if (name == "auto cycle")
    {
        g_AutoCycleEnabled = (value == "true" ||
            value == "yes");
    }
    else if (name == "base name")
    {
        g_BaseName = value;
    }
    else if (name == "inactivity delay")
    {
        g_InactivityDelay = (float)value;
        if (g_InactivityDelay < 5.0)
        {
            llOwnerSay("Inactivity delay must be at least 5 seconds, configuration specified "
                + (string)g_InactivityDelay + " seconds. Reverting to 5 seconds.");
            g_InactivityDelay = 5.0;
        }
    }
    else if (name == "offset")
    {
        g_DefaultOffset = (vector)value;
    }
    else if (name == "price")
    {
        integer price = parsePrice(value);
        
        if (price == -1)
        {
            llOwnerSay("Could not parse default price \""
                + value + "\".");
            return FALSE;
        }
        
        g_DefaultPrice = price;
    }
    else if (name == "rotation")
    {
        vector rotationDegrees = (vector)value;
        vector rotationRadians = rotationDegrees * DEG_TO_RAD;
        
        // Would be nice if this checked the format of the value provided.
        
        g_DefaultRotation = (rotation)llEuler2Rot(rotationRadians);
    }
    else if (name == "scan range")
    {
        g_ScanRange = (float)value;
        if (g_ScanRange < 1.0)
        {
            llOwnerSay("Scan range must be at least 1 metre, configuration specified "
                + (string)g_ScanRange + " metres. Reverting to 1 metre.");
            g_ScanRange = 1.0;
        }
        else if (g_ScanRange > 96.0)
        {
            llOwnerSay("Scan range cannot be over 96 metres, configuration specified "
                + (string)g_ScanRange + " metres. Reverting to 96 metres.");
            g_ScanRange = 96.0;
        }
    }
    else if (name == "silent")
    {
        value = llToLower(value);
        g_Silent = (value == "true" ||
            value == "yes");
    }
    else if (name == "spin rate")
    {
        float temp = (float)value;
        
        if (temp < 0.0)
        {
            llOwnerSay("Spin rate must be at least 0.0 radians/second, using 0.0 instead of supplied value of "
                + (string)temp + ".");
            return TRUE;
        }
        g_SpinRate = temp;
    }
    else if (name == "whisper")
    {
        value = llToLower(value);
        g_Whisper = !(value == "false" ||
            value == "no");
    }
    else
    {
        llOwnerSay("Unknown default parameter \""
            + name + "\"; valid names are; \"auto cycle\", \"base name\", \"inactivity delay\", \"offset\", \"price\", \"rotation\", \"scan range\", \"silent\", \"spin rate\" or \"whisper\".");
        return FALSE;
    }    
    
    return TRUE;
}

// Parses configuration parameters for an item to be sold; such as price,
// rez offset, name, etc.
//
// Returns TRUE on success, FALSE otherwise.
integer parseItemConfiguration(string name, string value)
{
    if (name == "name")
    {
        if (llGetInventoryType(value) == INVENTORY_NONE)
        {
            llOwnerSay("Could not find object \""
                + value + "\" in prim inventory, for rezzing.");
            return FALSE;
        }
        
        if (llGetInventoryType(value) != INVENTORY_OBJECT)
        {
            llOwnerSay("Asset \""
                + value + "\" in prim inventory is not an object, and therefore cannot be rezzed.");
            return FALSE;
        }
        
        if ((llGetInventoryPermMask(value, MASK_OWNER) & PERM_COPY) == 0)
        {
            llOwnerSay("You do not have copy permissions on the item \""
                + value + "\" in prim inventory, for rezzing.");
            return FALSE;
        }
        
        if (llListFindList(g_ProductDisplayNames, [value]) >= 0)
        {
            llOwnerSay("Object for rezzing \""
                + value + "\" referenced twice in configuration. You can only list a single object once, due to the name's use in the dialog menu.");
            return FALSE;
        }
        
        g_CurrentDisplayName = value;
    }
    else if (name == "offset")
    {
        vector offset = (vector)value;
        g_CurrentDisplayOffset = offset;
    }
    else if (name == "price")
    {
        integer price = parsePrice(value);
        
        if (price == -1)
        {
            llOwnerSay("Could not parse item price \""
                + value + "\".");
            return FALSE;
        }
        
        g_CurrentPrice = price;
    }
    else if (name == "vend")
    {
        integer testPerms = PERM_COPY & PERM_TRANSFER;
        
        if (llGetInventoryType(value) == INVENTORY_NONE)
        {
            llOwnerSay("Could not find asset \""
                + value + "\" in prim inventory, for delivery to customers.");
            return FALSE;
        }
        
        if ((llGetInventoryPermMask(value, MASK_OWNER) & testPerms) != testPerms)
        {
            llOwnerSay("You do not have copy & transfer on the item \""
                + value + "\" in prim inventory, for delivery to customers.");
            return FALSE;
        }
        
        g_CurrentContent = value;
    }
    else
    {
        llOwnerSay("Unknown item parameter \""
            + name + "\"; valid names are; name, offset, price, and vend.");
        return FALSE;
    }
    
    return TRUE;
}

// Parses a price, and converts into a number of Linden dollars. In case of a
// problem, returns -1
integer parsePrice(string data)
{
    integer price;
        
    if (llSubStringIndex(data, LINDEN_DOLLAR) == 0)
    {
        data = llGetSubString(data, llStringLength(LINDEN_DOLLAR), llStringLength(data));
        data = llStringTrim(data, STRING_TRIM);
    }
    price = (integer)data;
    
    if (((string)price) != data)
    {
        return -1;
    }
    
    if (price < 0)
    {
        return -1;
    }
    
    return price;
}

// Rezzes the object at the given index in the product lists, updates g_ItemIdx
// and g_Current* to match the object currently out.
rezObject(integer objectIdx)
{
    g_ItemIdx = objectIdx;
    
    g_CurrentDisplayName = llList2String(g_ProductDisplayNames, objectIdx);
    g_CurrentDisplayOffset = llList2Vector(g_ProductDisplayOffsets, objectIdx);
    g_CurrentPrice = llList2Integer(g_ProductPrices, objectIdx);
    g_CurrentContent = llList2String(g_ProductContents, objectIdx);
    
    if (g_CurrentContent == "")
    {
        g_CurrentContent = g_CurrentDisplayName;
    }
    
    // We want the position to be relative to the position the rezzer,
    // after taking into account the rotation of the rezzer. So, if it's
    // tilted, then "above" is no longer directly along the z axis, for
    // example.
    rotation currentRot = llGetRot();
    vector rezPosition = llGetPos() + (g_CurrentDisplayOffset * currentRot);
    rotation rezRotation = currentRot * g_DefaultRotation;

    llRezAtRoot(g_CurrentDisplayName, rezPosition, <0, 0, 0>, rezRotation, g_RezChannel);
    
    // To enable sales tracking from the owner's transactions list, the
    // vendor renames itself to match the object currently shown.
    if (g_BaseName == "")
    {
        llSetObjectName(g_CurrentDisplayName);
    }
    else
    {
        llSetObjectName(g_BaseName + " - "
            + g_CurrentDisplayName);
    }
        
    llSetPayPrice(PAY_HIDE, [g_CurrentPrice, PAY_HIDE, PAY_HIDE, PAY_HIDE]);
    if (!g_Silent)
    {
        string message = "Displaying "
            + g_CurrentDisplayName + ", available for L$"
            + (string)g_CurrentPrice;
        
        if (g_Whisper)
        {
            llWhisper(0, message);
        }
        else
        {
            llShout(0, message);
        }
    }
}

// This function shows the dialog menu to the active user. The parameter passed
// to it is a page increment/decrement. Intended to be -1, 0 or 1, but any
// value should provide the expected result.
showDialog(integer pageChange)
{
    list buttons = [];
    integer itemCount = llGetListLength(g_ProductDisplayNames);
    integer buttonIdx;
    integer temp;
    integer buttonCount;

    // Modify by the page change    
    g_ItemIdx += (pageChange * OBJECTS_PER_DIALOG);
    g_ItemIdx = g_ItemIdx - (g_ItemIdx % OBJECTS_PER_DIALOG);
    
    // If page change takes it out of bounds, loop around.
    if (g_ItemIdx < 0)
    {
        g_ItemIdx = itemCount - (itemCount % OBJECTS_PER_DIALOG);
    }
    else if (g_ItemIdx > itemCount)
    {
        g_ItemIdx = 0;
    }
    
    // Add next, previous and clear buttons as needed
    if (itemCount > MAX_DIALOG_BUTTONS)
    {
        buttonCount = OBJECTS_PER_DIALOG;
        
        buttons += BUTTON_NEXT;
        buttons += BUTTON_PREV;
    }
    else
    {
        buttonCount = MAX_DIALOG_BUTTONS;
    }
    
    if (buttonCount > (itemCount - g_ItemIdx))
    {
        buttonCount = (itemCount - g_ItemIdx);
    }
    
    buttons += llList2List(g_ProductDisplayNames, g_ItemIdx, g_ItemIdx + (buttonCount - 1));
    // Check the buttons for any that are over the maximum length for a dialog
    // button label
    for (buttonIdx = 0; buttonIdx < buttonCount; buttonIdx++)
    {
        string buttonName = llList2String(buttons, buttonIdx);
        
        if (llStringLength(buttonName) > MAX_BUTTON_LENGTH)
        {
            buttonName = llGetSubString(buttonName, 0, MAX_BUTTON_LENGTH - 1);
            buttons = llListReplaceList(buttons, [buttonName], buttonIdx, buttonIdx);
        }
    }

    if (itemCount > MAX_DIALOG_BUTTONS)
    {
        integer pageCount = itemCount / OBJECTS_PER_DIALOG;
        integer pageIdx = (g_ItemIdx + 1) / OBJECTS_PER_DIALOG;

        if (((g_ItemIdx + 1) % OBJECTS_PER_DIALOG) > 0)
        {    
            pageIdx++;
        }

        if ((itemCount % OBJECTS_PER_DIALOG) > 0)
        {
            pageCount++;
        }

        llDialog(g_ActiveUserKey, "Please select a product to display (p "
            + (string)pageIdx + "/"
            + (string)pageCount + ")", buttons, g_DialogChannel);
    }
    else
    {
        llDialog(g_ActiveUserKey, "Please select a product to display", buttons, g_DialogChannel);
    }
    
    return;
}

// Clears the current configuration, and then starts reading the configuration
// notecard from the first line. Returns TRUE if it succeeds in starting
// configuration load, false otherwise.
integer startConfigurationRead()
{
    integer notecardType = llGetInventoryType(CONFIGURATION_NOTECARD_NAME);

    g_ConfiguringItem = FALSE;

    g_ProductDisplayNames = [];
    g_ProductDisplayOffsets = [];
    g_ProductPrices = [];
    g_ProductContents = [];
    
    if (notecardType != INVENTORY_NOTECARD)
    {
        llOwnerSay("Error: Expected a notecard in inventory called \""
            + CONFIGURATION_NOTECARD_NAME + "\". Without it, I cannot load prices and object details.");
        return FALSE;
    }
    
    if (llGetInventoryKey(CONFIGURATION_NOTECARD_NAME) == NULL_KEY) {
        llOwnerSay("Warning: Couldn't retrieve UUID (key) for notecard \""
            + CONFIGURATION_NOTECARD_NAME + "\"; this could mean it's empty or not full perms. Going to try loading it anyway, but this will fail if the notecard is empty.");
    }

    llOwnerSay("Starting configuration load from notecard...");
    g_NotecardLine = 0;
    g_NotecardQuery = llGetNotecardLine(CONFIGURATION_NOTECARD_NAME, g_NotecardLine++);

    return TRUE;
}

// Checks the last product loaded from the configuration notecard has all the
// fields necessary, and adds it to the product lists if so.
integer validateAndAddItem()
{    
    if (g_CurrentDisplayName == "")
    {
        llOwnerSay("No name provided for item #"
            + (string)(llGetListLength(g_ProductDisplayNames) + 1) + ".");
        return FALSE;
    }
    
    g_ProductDisplayNames += g_CurrentDisplayName;
    g_ProductDisplayOffsets += g_CurrentDisplayOffset;
    g_ProductPrices += g_CurrentPrice;
    g_ProductContents += g_CurrentContent;
    
    return TRUE;
}

// Default state does one time setup (if necessary) of requesting debit
// permissions so that it can refund on mis-transactions, and generating
// channel numbers to communicate on. It then reads configuration from the
// notecard, and if configured successfully continues to the ready state.
default
{
    changed(integer changeType)
    {
        if (changeType & CHANGED_OWNER)
        {
            llResetScript();
        }

        if (changeType & CHANGED_INVENTORY)
        {
            startConfigurationRead();
        }
    }
    
    dataserver(key queryID, string data)
    {
        if (queryID != g_NotecardQuery)
        {
            return;
        }
        
        if (data == EOF)
        {
            if (llGetListLength(g_ProductDisplayNames) == 0)
            {
                llOwnerSay("No items configured to sell. You need to add \"[item]\" sections to the configuration.");
                return;
            }
            
            if (!validateAndAddItem())
            {
                return;
            }

            // Checks the contents of the prim inventory for any objects which are not in
            // the configuration (not an error, but important to warn the user of).
            integer objectCount = llGetInventoryNumber(INVENTORY_OBJECT);
            integer objectIdx;
        
            for (objectIdx = 0; objectIdx < objectCount; objectIdx++)
            {
                string objectName = llGetInventoryName(INVENTORY_OBJECT, objectIdx);
            
                if (llListFindList(g_ProductDisplayNames, [objectName]) < 0 &&
                    llListFindList(g_ProductContents, [objectName]) < 0)
                {
                    llOwnerSay("Warning: Object \""
                        + objectName + "\" in prim inventory is not referenced in the configuration notecard.");
                }
            }
        
            state ready;
        }
            
        if (!parseConfigurationLine(data))
        {
            return;
        }
 
        // Request the next line
        g_NotecardQuery = llGetNotecardLine(CONFIGURATION_NOTECARD_NAME, g_NotecardLine++);
    }
    
    state_entry()
    {
        if (!g_OneTimeSetupPerformed)
        {        
            llOwnerSay("I'm going to request debit permissions. You DO NOT have to grant these, but if you do I can auto-refund mis-payments.");
            llRequestPermissions(llGetOwner(), PERMISSION_DEBIT);
            g_OneTimeSetupPerformed = TRUE;
        }
        
        // Generate chat channels for use when with the dialog menus
        // and rezzed objects
        g_DialogChannel = -200 - llFloor(llFrand(2000000.0));
        g_RezChannel = -200 - llFloor(llFrand(2000000.0));
        
        // If this fails, we just stay in the configuration reading state until
        // inventory changes.
        startConfigurationRead();
    }
    
    touch_start(integer detectedCount)
    {
        integer detectedIdx;
        
        for (detectedIdx = 0; detectedIdx < detectedCount; detectedIdx++)
        {
            key avatarKey = llDetectedKey(detectedIdx);

            if (avatarKey == llGetOwner())
            {
                llOwnerSay("Re-attempting configuration load due to owner touch.");
                startConfigurationRead();
            }
            else
            {
                llInstantMessage(avatarKey, "I have not yet successfully completed configuration.");
            }
        }
    }
}

// Once the notecard has been read in and verified, the script progresses to the
// ready state, which reflects that it is, erm, ready...
state ready
{
    changed(integer changeType)
    {
        if (changeType & CHANGED_OWNER)
        {
            llResetScript();
        }
        
        if (changeType & CHANGED_INVENTORY)
        {
            state default;
        }
    }
    
    sensor(integer numDetected)
    {
        // Avatars detected nearby, but haven't clicked. Go into auto-cycle
        // mode;
        state auto_cycle;
    }
    
    on_rez(integer startParam)
    {
        // Reset to ensure we get new chat channels, and generally also clear
        // out the cobwebs
        llResetScript();
    }
    
    state_entry()
    {
        if (g_BaseName == "")
        {
            llSetObjectName("Holo vendor");
        }
        else
        {
            llSetObjectName("Holo vendor - "
                + g_BaseName);
        }
        
        if (!g_Silent)
        {
            if (g_Whisper)
            {
                llWhisper(0, "Ready");
            }
            else
            {
                llShout(0, "Ready");
            }
        }
        
        if (g_AutoCycleEnabled)
        {
            llSensorRepeat("", NULL_KEY, AGENT, g_ScanRange, TWO_PI, g_AutoCycleTime);
        }
    }
    
    state_exit()
    {
        llSensorRemove();
    }
    
    touch_end(integer detectedCount)
    {
        integer detectedIdx;
        
        for (detectedIdx = 0; detectedIdx < detectedCount; detectedIdx++)
        {
            g_ActiveUserKey = llDetectedKey(detectedIdx);
            g_ActiveUserTime = llGetUnixTime();

            state active;
        }
    }
}

// The active state means the rezzer is listening. This increases lag, so if
// the script detects no avatars nearby, it reverts back to the ready state.
state active
{
    changed(integer changeType)
    {
        if (changeType & CHANGED_OWNER)
        {
            llResetScript();
        }
        
        if (changeType & CHANGED_INVENTORY)
        {
            state default;
        }
    }
    
    // Takes in commands from users, and moves between dialog pages/shows
    // new items, as needed.
    listen(integer channel, string name, key id, string message)
    {
        integer toClear = FALSE;
        integer rezIdx = -1;
        
        if (id != g_ActiveUserKey)
        {
            return;
        }
        
        g_ActiveUserTime = llGetUnixTime();
        if (message == BUTTON_NEXT)
        {
            showDialog(1);
        }
        else if (message == BUTTON_PREV)
        {
            showDialog(-1);
        }
        else
        {
            rezIdx = llListFindList(g_ProductDisplayNames, [message]);
            if (rezIdx >= 0)
            {
                integer objectCount = llGetInventoryNumber(INVENTORY_OBJECT);
                integer objectIdx;
                string objectName = "";
                
                llShout(g_RezChannel, MSG_DIE);
                
                for (objectIdx = 0; objectIdx < objectCount && objectName == ""; objectIdx++)
                {
                    string temp = llGetInventoryName(INVENTORY_OBJECT, objectIdx);
                        
                    if (llSubStringIndex(temp, message) == 0) {
                        objectName = temp;
                    }
                }
                
                rezObject(rezIdx);
            }
        }
    }
    
    money(key id, integer amount)
    {
        handleSale(id, amount);
    }
    
    // If the avatar leaves the area for at least the inactivity delay in seconds,
    // go inactive to reduce lag.
    no_sensor()
    {
        integer time = llGetUnixTime();
                
        if ((time - g_ActiveUserTime) >= g_InactivityDelay)
        {
            state ready;
        }
    }
    
    object_rez(key id)
    {
        if (g_SpinRate > 0.0)
        {
            llShout(g_RezChannel, MSG_SPIN
                + (string)<0.0, 0.0, 1.0> + ":"
                + (string)g_SpinRate + ":1.0");
        }
        llShout(g_RezChannel, MSG_SELL
            + (string)g_CurrentPrice + ":"
            + (string)g_CurrentContent);
        llGiveInventory(id, g_CurrentContent);
    }

    on_rez(integer startParam)
    {
        llShout(g_RezChannel, MSG_DIE);
        // Reset to ensure we get new chat channels, and generally also clear
        // out the cobwebs
        llResetScript();
    }
    
    sensor(integer detectedCount)
    {
        // This is just here to make no_sensor() work
    }
    
    state_entry()
    {
        rezObject(0);
        showDialog(0);

        llSensorRepeat("", g_ActiveUserKey, AGENT, g_ScanRange, PI, g_InactivityDelay);
        g_ListenHandle = llListen(g_DialogChannel, "", g_ActiveUserKey, "");
    }

    state_exit()
    {
        llShout(g_RezChannel, MSG_DIE);

        llListenRemove(g_ListenHandle);
        llSensorRemove();
    }
    
    touch_end(integer detectedCount)
    {
        integer detectedIdx;
        
        for (detectedIdx = 0; detectedIdx < detectedCount; detectedIdx++)
        {
            key avatarKey = llDetectedKey(detectedIdx);
            
            if (avatarKey != g_ActiveUserKey)
            {
                integer time = llGetUnixTime();
                
                if ((time - g_ActiveUserTime) < g_InactivityDelay)
                {
                    llInstantMessage(llDetectedKey(detectedIdx), "Sorry, I am currently locked to another user.");
                    return;
                }
                else
                {
                    g_ActiveUserKey = avatarKey;
                    g_ItemIdx = 0;
                    llSensorRepeat("", g_ActiveUserKey, AGENT, g_ScanRange, PI, g_InactivityDelay);
                    llListenRemove(g_ListenHandle);
                    g_ListenHandle = llListen(g_DialogChannel, "", g_ActiveUserKey, "");
                }
            }
            
            g_ActiveUserTime = llGetUnixTime();
            showDialog(0);
        }
    }
}

// If people are around, but no-one's interacting with the vendor, cycle
// through items
state auto_cycle
{
    changed(integer changeType)
    {
        if (changeType & CHANGED_OWNER)
        {
            llResetScript();
        }
        
        if (changeType & CHANGED_INVENTORY)
        {
            state default;
        }
    }
    
    money(key id, integer amount)
    {
        handleSale(id, amount);
    }
    
    // If the avatar leaves the area for at least the inactivity delay in seconds,
    // go inactive to reduce lag.
    no_sensor()
    {
        state ready;
    }
    
    object_rez(key id)
    {
        if (g_SpinRate > 0.0)
        {
            llShout(g_RezChannel, MSG_SPIN
                + (string)<0.0, 0.0, 1.0> + ":"
                + (string)g_SpinRate + ":1.0");
        }
        llShout(g_RezChannel, MSG_SELL
            + (string)g_CurrentPrice + ":"
            + (string)g_CurrentContent);
        llGiveInventory(id, g_CurrentContent);
    }

    on_rez(integer startParam)
    {
        llShout(g_RezChannel, MSG_DIE);
        // Reset to ensure we get new chat channels, and generally also clear
        // out the cobwebs
        llResetScript();
    }
    
    sensor(integer detectedCount)
    {
        // This is just here to make no_sensor() work
    }
    
    state_entry()
    {
        rezObject(0);

        llSensorRepeat("", NULL_KEY, AGENT, g_ScanRange, PI, g_InactivityDelay);
        llSetTimerEvent(g_AutoCycleTime);
    }

    state_exit()
    {        
        llSetTimerEvent(0.0);
        llShout(g_RezChannel, MSG_DIE);

        llSensorRemove();
    }
    
    timer()
    {
        string objectName;
        
        // g_ItemIdx is set by rezObject to always track the last object rezzed,
        // and we want to show the next so we increment.
        g_ItemIdx++;
        if (g_ItemIdx >= llGetListLength(g_ProductDisplayNames))
        {
            g_ItemIdx = 0;
        }
        
        llShout(g_RezChannel, MSG_DIE);
        rezObject(g_ItemIdx);
    }
    
    touch_end(integer detectedCount)
    {
        integer detectedIdx;
        
        for (detectedIdx = 0; detectedIdx < detectedCount; detectedIdx++)
        {
            g_ActiveUserKey = llDetectedKey(detectedIdx);
            g_ActiveUserTime = llGetUnixTime();

            state active;
        }
    }
}
