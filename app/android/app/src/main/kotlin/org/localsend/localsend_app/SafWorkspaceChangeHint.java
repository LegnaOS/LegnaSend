package org.localsend.localsend_app;

import java.util.Objects;

/** Optional provider metadata is only an invalidation hint, never file identity. */
final class SafWorkspaceChangeHint {
    private boolean initialized;
    private Long modified;

    boolean observe(Long value) {
        Long current = value != null && value > 0 ? value : null;
        boolean changed = initialized && !Objects.equals(modified, current);
        modified = current;
        initialized = true;
        return changed;
    }
}
